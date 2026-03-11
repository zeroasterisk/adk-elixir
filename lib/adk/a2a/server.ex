defmodule ADK.A2A.Server do
  @moduledoc """
  A2A protocol server for ADK agents, implemented as a Plug.

  Wraps `A2A.Plug` from the [a2a](https://github.com/zeroasterisk/a2a-elixir)
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
        :ets.new(name, [:named_table, :public, :set])

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

    # Start the bridging A2A agent GenServer
    bridge_name = :"adk_a2a_bridge_#{config_table_name}"

    case GenServer.whereis(bridge_name) do
      nil ->
        {:ok, _pid} =
          ADK.A2A.Server.Bridge.start_link(
            name: bridge_name,
            config_table: config_table,
            task_store: {A2A.TaskStore.ETS, task_table}
          )

      _pid ->
        :ok
    end

    # Initialize A2A.Plug pointing at our bridge agent
    plug_config =
      A2A.Plug.init(
        agent: bridge_name,
        base_url: url,
        agent_card_path: [".well-known", "agent.json"]
      )

    plug_config
    |> Map.put(:adk_config_table, config_table)
    |> Map.put(:table, task_table)
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, config) do
    A2A.Plug.call(conn, config)
  end
end

defmodule ADK.A2A.Server.Bridge do
  @moduledoc false
  # A GenServer that implements the A2A agent protocol expected by A2A.Plug.
  # Delegates actual work to ADK.Runner via config stored in an ETS table.

  use GenServer

  @behaviour A2A.Agent

  # -- Client API --

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # -- A2A.Agent callbacks (used by our GenServer, not by A2A.Plug directly) --

  @impl A2A.Agent
  def agent_card do
    %{name: "adk-bridge", description: "ADK Bridge Agent", version: "1.0.0", skills: [], opts: []}
  end

  @impl A2A.Agent
  def handle_message(message, context) do
    adk_config = Process.get(:adk_bridge_config)

    if adk_config do
      text = extract_text(message)
      user_id = "a2a-user"
      session_id = "a2a-#{context.task_id}"

      events = ADK.Runner.run(adk_config.runner, user_id, session_id, text)

      parts =
        events
        |> Enum.flat_map(fn event ->
          case event do
            %{content: %{parts: parts}} when is_list(parts) ->
              Enum.map(parts, fn
                %{text: t} when is_binary(t) -> A2A.Part.Text.new(t)
                _ -> nil
              end)

            _ ->
              []
          end
        end)
        |> Enum.reject(&is_nil/1)

      case parts do
        [] -> {:reply, [A2A.Part.Text.new("No response")]}
        parts -> {:reply, parts}
      end
    else
      {:reply, [A2A.Part.Text.new("Bridge not configured")]}
    end
  end

  @impl A2A.Agent
  def handle_cancel(_context), do: :ok

  defp extract_text(%A2A.Message{parts: parts}) do
    parts
    |> Enum.map(fn
      %A2A.Part.Text{text: t} -> t
      _ -> ""
    end)
    |> Enum.join(" ")
  end

  defp extract_text(other), do: to_string(other)

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    config_table = Keyword.fetch!(opts, :config_table)
    task_store = Keyword.get(opts, :task_store)

    Process.put(:adk_bridge_config_table, config_table)

    {:ok,
     %A2A.Agent.State{
       module: __MODULE__,
       task_store: task_store
     }}
  end

  @impl GenServer
  def handle_call({:message, message, opts}, _from, state) do
    # Inject ADK config into process dictionary for handle_message callback
    config_table = Process.get(:adk_bridge_config_table)

    if config_table do
      case :ets.lookup(config_table, :config) do
        [{:config, adk_config}] -> Process.put(:adk_bridge_config, adk_config)
        _ -> :ok
      end
    end

    # Replicate the logic from A2A.Agent.__using__ handle_call({:message, ...})
    task_id = Keyword.get(opts, :task_id)
    _context_id = Keyword.get(opts, :context_id)
    metadata = Keyword.get(opts, :metadata, %{})

    result =
      if task_id do
        case A2A.Agent.State.get_task(state, task_id) do
          {:ok, task} ->
            A2A.Agent.Runtime.continue_task(__MODULE__, message, task, state)

          {:error, :not_found} ->
            {:error, :not_found}
        end
      else
        context_id = Keyword.get(opts, :context_id)

        {:ok,
         A2A.Agent.Runtime.process_message(
           __MODULE__,
           message,
           context_id,
           state,
           metadata
         )}
      end

    case result do
      {:ok, {task, state}} ->
        state = A2A.Agent.State.put_task(state, task)
        {:reply, {:ok, task}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, task_id}, _from, state) do
    case A2A.Agent.State.get_task(state, task_id) do
      {:ok, task} ->
        if task.status.state in [:completed, :canceled, :failed] do
          {:reply, {:error, :not_cancelable}, state}
        else
          context = %{
            task_id: task.id,
            context_id: task.context_id,
            history: task.history,
            metadata: task.metadata
          }

          case A2A.Agent.Runtime.run_cancel(__MODULE__, context) do
            :ok ->
              task = A2A.Agent.State.transition(task, :canceled)
              state = A2A.Agent.State.put_task(state, task)
              {:reply, :ok, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_task, task_id}, _from, state) do
    {:reply, A2A.Agent.State.get_task(state, task_id), state}
  end

  def handle_call({:list_tasks, params}, _from, state) do
    {:reply, A2A.Agent.State.list_tasks(state, params), state}
  end

  def handle_call(:get_agent_card, _from, state) do
    config_table = Process.get(:adk_bridge_config_table)

    card =
      if config_table do
        case :ets.lookup(config_table, :config) do
          [{:config, adk_config}] ->
            url = adk_config[:url] || adk_config.url || "http://localhost:4000"
            card_opts = adk_config[:card_opts] || adk_config.card_opts || []
            agent = adk_config[:agent] || adk_config.agent

            a2a_card = ADK.A2A.AgentCard.to_a2a_card(agent, Keyword.merge(card_opts, url: url))
            card_data = A2A.JSON.encode_agent_card(a2a_card, url: url)

            %{
              name: card_data["name"] || "adk-bridge",
              description: card_data["description"] || "",
              version: card_data["version"] || "1.0.0",
              skills:
                (card_data["skills"] || [])
                |> Enum.map(fn s ->
                  %{
                    id: s["id"] || "unknown",
                    name: s["name"] || "unknown",
                    description: s["description"] || "",
                    tags: s["tags"] || []
                  }
                end),
              opts: []
            }

          _ ->
            agent_card()
        end
      else
        agent_card()
      end

    {:reply, card, state}
  end

  @impl GenServer
  def handle_cast({:stream_done, task_id, parts}, state) do
    case A2A.Agent.State.get_task(state, task_id) do
      {:ok, task} ->
        artifact = A2A.Artifact.new(parts)
        agent_msg = A2A.Message.new_agent(parts)
        task = %{task | artifacts: task.artifacts ++ [artifact]}
        task = %{task | history: task.history ++ [agent_msg]}
        task = %{task | metadata: Map.delete(task.metadata, :stream)}
        task = A2A.Agent.State.transition(task, :completed)
        state = A2A.Agent.State.put_task(state, task)
        {:noreply, state}

      {:error, :not_found} ->
        {:noreply, state}
    end
  end
end
