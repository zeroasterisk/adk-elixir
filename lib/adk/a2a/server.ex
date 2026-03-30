if Code.ensure_loaded?(A2A.AgentCard) do
  defmodule ADK.A2A.Server do
    @moduledoc """
    A2A protocol server for ADK agents, implemented as a Plug.

    Wraps `A2A.Plug` from the [a2a](https://github.com/zeroasterisk/a2a-elixir)
    package with ADK-specific handler logic (running agents via `ADK.Runner`).

    Serves the Agent Card at `GET /.well-known/agent-card.json` and handles
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

      :ets.insert(
        config_table,
        {:config, %{agent: agent, runner: runner, card_opts: card_opts, url: url}}
      )

      # Create or reuse a named ETS table for tasks
      task_table_name = Keyword.get(opts, :task_table_name, :adk_a2a_tasks)
      _task_table = ensure_table(task_table_name)

      # Build ADK bridge agent module dynamically
      bridge_agent = ADK.A2A.Server.BridgeAgent

      # Store config for the bridge
      Process.put(:adk_a2a_config_table, config_table)

      # Initialize the A2A Plug
      plug_config =
        A2A.Plug.init(
          agent: bridge_agent,
          base_url: url
        )

      plug_config
      |> Map.put(:adk_config_table, config_table)
    end

    @impl Plug
    @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def call(conn, config) do
      # Inject config table name into process dictionary so the handler can find it
      Process.put(:adk_a2a_config_table, config.adk_config_table)
      A2A.Plug.call(conn, config)
    end
  end

  defmodule ADK.A2A.Server.BridgeAgent do
    @moduledoc false
    @behaviour A2A.Agent

    @impl A2A.Agent
    def agent_card do
      config_table = Process.get(:adk_a2a_config_table)

      if config_table do
        case :ets.lookup(config_table, :config) do
          [{:config, adk_config}] ->
            url = adk_config.url
            card_opts = adk_config.card_opts || []
            agent = adk_config.agent
            ADK.A2A.AgentCard.to_a2a_card(agent, Keyword.merge(card_opts, url: url))

          _ ->
            default_card()
        end
      else
        default_card()
      end
    end

    @impl A2A.Agent
    def handle_message(message, context) do
      config_table = Process.get(:adk_a2a_config_table)

      if config_table do
        case :ets.lookup(config_table, :config) do
          [{:config, adk_config}] ->
            text = A2A.Message.text(message) || ""
            user_id = Map.get(context, :user_id, "a2a-user")
            session_id = Map.get(context, :session_id, "a2a-session")

            try do
              events = ADK.Runner.run(adk_config.runner, user_id, session_id, text)
              last_text = events |> List.last() |> ADK.Event.text()
              {:reply, last_text || ""}
            rescue
              e ->
                {:error, Exception.message(e)}
            end

          _ ->
            {:error, "Bridge not configured"}
        end
      else
        {:error, "Bridge not configured"}
      end
    end

    @impl A2A.Agent
    def handle_cancel(_context) do
      :ok
    end

    defp default_card do
      %A2A.AgentCard{
        name: "adk-bridge",
        description: "ADK Bridge Agent",
        url: "http://localhost:4000",
        version: "1.0",
        skills: []
      }
    end
  end
else
  defmodule ADK.A2A.Server do
    @moduledoc "Requires {:a2a, \"~> 0.2\"} optional dependency. Install it to enable A2A protocol support."
  end
end
