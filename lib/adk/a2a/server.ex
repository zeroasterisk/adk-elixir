defmodule ADK.A2A.Server do
  @moduledoc """
  A2A protocol server for ADK agents, implemented as a Plug.

  Wraps `A2A.Server` from the [a2a](https://github.com/zeroasterisk/a2a-elixir)
  package with ADK-specific handler logic (running agents via `ADK.Runner`).

  Serves the Agent Card at `GET /.well-known/agent.json` and handles
  JSON-RPC 2.0 requests at `POST /`.

  ## Usage

      plug ADK.A2A.Server,
        agent: my_agent_spec,
        runner: %ADK.Runner{app_name: "my_app", agent: my_agent_spec},
        url: "http://localhost:4000/a2a"
  """

  @behaviour Plug

  @doc false
  def ensure_table(name) do
    case :ets.whereis(name) do
      :undefined ->
        try do
          :ets.new(name, [:named_table, :public, :set])
        rescue
          ArgumentError -> name
        end

      _ref ->
        name
    end
  end

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    agent = Keyword.fetch!(opts, :agent)
    runner = Keyword.fetch!(opts, :runner)
    url = Keyword.get(opts, :url, "http://localhost:4000")
    card_opts = Keyword.get(opts, :card_opts, [])

    # Create or reuse a named ETS table to store our ADK config
    config_table_name = Keyword.get(opts, :config_table_name, :adk_a2a_config)
    config_table = ensure_table(config_table_name)
    :ets.insert(config_table, {:config, %{agent: agent, runner: runner, card_opts: card_opts, url: url}})

    # Create or reuse a named ETS table for tasks
    task_table_name = Keyword.get(opts, :task_table_name, :adk_a2a_tasks)
    task_table = ensure_table(task_table_name)

    # Initialize A2A.Server with our handler
    a2a_config =
      A2A.Server.init(
        handler: ADK.A2A.Server.Handler,
        url: url,
        table: task_table,
        card_opts: [config_table: config_table]
      )

    a2a_config
    |> Map.put(:adk_config_table, config_table)
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, config) do
    # Inject config table name into process dictionary so the handler can find it
    Process.put(:adk_a2a_config_table, config.adk_config_table)
    A2A.Server.call(conn, config)
  end
end

defmodule ADK.A2A.Server.Handler do
  @moduledoc false
  # Implements A2A.Handler behaviour for ADK.
  # Delegates work to ADK.Runner using config stored in ETS.

  @behaviour A2A.Handler

  @impl A2A.Handler
  def agent_card(opts) do
    # Retrieve config table from card_opts or process dict
    config_table = opts[:opts][:config_table] || Process.get(:adk_a2a_config_table)

    if config_table do
      case :ets.lookup(config_table, :config) do
        [{:config, adk_config}] ->
          url = adk_config.url || opts.url
          card_opts = adk_config.card_opts || []
          agent = adk_config.agent

          ADK.A2A.AgentCard.to_a2a_card(agent, Keyword.merge(card_opts, url: url))

        _ ->
          default_card(opts.url)
      end
    else
      default_card(opts.url)
    end
  end

  @impl A2A.Handler
  def handle_message(message_text, params) do
    config_table = Process.get(:adk_a2a_config_table)

    if config_table do
      case :ets.lookup(config_table, :config) do
        [{:config, adk_config}] ->
          # Use user_id from params if available, else default
          # v1.0 spec doesn't have a top-level userId in SendMessage, 
          # but it might be in metadata or we use a fixed one.
          user_id = params["userId"] || "a2a-user"
          session_id = params["contextId"] || params["taskId"] || "a2a-session"

          try do
            events = ADK.Runner.run(adk_config.runner, user_id, session_id, message_text)
            messages = Enum.map(events, &ADK.A2A.Message.to_a2a_message/1)
            artifacts = extract_artifacts(events)
            # IO.inspect({:returning_from_handler, messages, artifacts})
            {:ok, messages, artifacts}
          rescue
            e ->
              # IO.inspect({:error_in_handler, e, __STACKTRACE__})
              {:error, Exception.message(e)}
          end

        _ ->
          {:error, "Bridge not configured (no config in table)"}
      end
    else
      {:error, "Bridge not configured (no table in process dict)"}
    end
  end

  defp default_card(url) do
    A2A.AgentCard.new(
      name: "adk-bridge",
      description: "ADK Bridge Agent",
      url: url
    )
  end

  defp extract_artifacts(events) do
    events
    |> Enum.flat_map(fn
      %{content: %{parts: parts}} when is_list(parts) ->
        parts
        |> Enum.map(fn
          %{text: t} when is_binary(t) -> A2A.Part.text(t)
          %{"text" => t} -> A2A.Part.text(t)
          %{file: u} -> A2A.Part.file_url(u)
          %{"file" => u} -> A2A.Part.file_url(u)
          %{data: d} -> A2A.Part.data(d)
          %{"data" => d} -> A2A.Part.data(d)
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> []
          parts -> [A2A.Artifact.new(parts)]
        end

      _ ->
        []
    end)
  end
end
