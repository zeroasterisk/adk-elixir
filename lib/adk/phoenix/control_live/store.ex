if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule ADK.Phoenix.ControlLive.Store do
    @moduledoc """
    In-memory telemetry event accumulator for the ControlPlane dashboard.

    Attaches to all `:adk.*` telemetry events on start, accumulates them in
    ring buffers (last N events per category), and broadcasts updates via
    Phoenix PubSub so LiveView subscribers get real-time updates.

    ## Usage

        # Start as part of supervision tree
        {ADK.Phoenix.ControlLive.Store, pubsub: MyApp.PubSub}

        # Or standalone
        ADK.Phoenix.ControlLive.Store.start_link(pubsub: MyApp.PubSub)

        # Get current state
        ADK.Phoenix.ControlLive.Store.get_state()

    ## Configuration

    - `:pubsub` — Phoenix.PubSub server name (required)
    - `:max_events` — max events per ring buffer (default: 100)
    - `:name` — GenServer name (default: `__MODULE__`)
    """

    use GenServer

    @default_max 100
    @topic "adk:control_plane"
    @handler_id "adk.control_live.store"

    # ── Public API ──────────────────────────────────────────────────────

    @doc "Start the store. Requires `:pubsub` option."
    def start_link(opts \\ []) do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @doc "Get the accumulated state snapshot."
    @spec get_state(GenServer.server()) :: map()
    def get_state(server \\ __MODULE__) do
      GenServer.call(server, :get_state)
    end

    @doc "Get the PubSub topic for subscribing to updates."
    @spec topic() :: String.t()
    def topic, do: @topic

    @doc "Clear all accumulated events."
    @spec clear(GenServer.server()) :: :ok
    def clear(server \\ __MODULE__) do
      GenServer.call(server, :clear)
    end

    # ── GenServer Callbacks ─────────────────────────────────────────────

    @impl true
    def init(opts) do
      pubsub = Keyword.get(opts, :pubsub)
      max = Keyword.get(opts, :max_events, @default_max)

      # Attach telemetry handlers
      events = ADK.Telemetry.Contract.all_events()

      :telemetry.attach_many(
        @handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        %{server: Keyword.get(opts, :name, __MODULE__)}
      )

      state = %{
        pubsub: pubsub,
        max: max,
        sessions: [],
        runs: [],
        tools: [],
        llm: [],
        errors: []
      }

      {:ok, state}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, snapshot(state), state}
    end

    def handle_call(:clear, _from, state) do
      cleared = %{state | sessions: [], runs: [], tools: [], llm: [], errors: []}
      {:reply, :ok, cleared}
    end

    @impl true
    def handle_cast({:telemetry_event, category, entry}, state) do
      new_state = push_event(state, category, entry)
      broadcast(new_state)
      {:noreply, new_state}
    end

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, _state) do
      :telemetry.detach(@handler_id)
      :ok
    end

    # ── Telemetry Handler (called by :telemetry) ────────────────────────

    @doc false
    def handle_telemetry_event(event, measurements, metadata, config) do
      server = config[:server] || __MODULE__

      {category, entry} = classify_event(event, measurements, metadata)

      if category do
        GenServer.cast(server, {:telemetry_event, category, entry})
      end
    end

    # ── Private ─────────────────────────────────────────────────────────

    defp classify_event([:adk, :runner, phase], measurements, metadata) do
      {:runs,
       %{
         id: System.unique_integer([:positive]),
         phase: phase,
         agent_name: metadata[:agent_name] || "unknown",
         session_id: metadata[:session_id],
         user_id: metadata[:user_id],
         app_name: metadata[:app_name],
         duration: format_duration(measurements[:duration]),
         status: if(phase == :exception, do: :error, else: :ok),
         timestamp: DateTime.utc_now()
       }}
    end

    defp classify_event([:adk, :session, phase], measurements, metadata) do
      {:sessions,
       %{
         id: System.unique_integer([:positive]),
         phase: phase,
         session_id: metadata[:session_id],
         user_id: metadata[:user_id],
         app_name: metadata[:app_name],
         duration: format_duration(measurements[:duration]),
         timestamp: DateTime.utc_now()
       }}
    end

    defp classify_event([:adk, :tool, phase], measurements, metadata) do
      entry = %{
        id: System.unique_integer([:positive]),
        phase: phase,
        tool_name: metadata[:tool_name] || "unknown",
        agent_name: metadata[:agent_name] || "unknown",
        session_id: metadata[:session_id],
        duration: format_duration(measurements[:duration]),
        status: if(phase == :exception, do: :error, else: :ok),
        timestamp: DateTime.utc_now()
      }

      if phase == :exception do
        {:errors, Map.put(entry, :category, :tool)}
      else
        {:tools, entry}
      end
    end

    defp classify_event([:adk, :llm, phase], measurements, metadata) do
      entry = %{
        id: System.unique_integer([:positive]),
        phase: phase,
        model: metadata[:model] || "unknown",
        agent_name: metadata[:agent_name] || "unknown",
        session_id: metadata[:session_id],
        duration: format_duration(measurements[:duration]),
        input_tokens: metadata[:input_tokens],
        output_tokens: metadata[:output_tokens],
        status: if(phase == :exception, do: :error, else: :ok),
        timestamp: DateTime.utc_now()
      }

      if phase == :exception do
        {:errors, Map.put(entry, :category, :llm)}
      else
        {:llm, entry}
      end
    end

    defp classify_event([:adk, :agent, phase], measurements, metadata) do
      entry = %{
        id: System.unique_integer([:positive]),
        phase: phase,
        agent_name: metadata[:agent_name] || "unknown",
        session_id: metadata[:session_id],
        duration: format_duration(measurements[:duration]),
        status: if(phase == :exception, do: :error, else: :ok),
        timestamp: DateTime.utc_now()
      }

      if phase == :exception do
        {:errors, Map.put(entry, :category, :agent)}
      else
        # Agent events are tracked under runs
        {:runs, entry}
      end
    end

    defp classify_event(_event, _measurements, _metadata), do: {nil, nil}

    defp format_duration(nil), do: nil

    defp format_duration(native) when is_integer(native) do
      # Convert from native time units to microseconds
      System.convert_time_unit(native, :native, :microsecond)
    end

    defp format_duration(_), do: nil

    defp push_event(state, category, entry) do
      current = Map.get(state, category, [])
      updated = Enum.take([entry | current], state.max)
      Map.put(state, category, updated)
    end

    defp snapshot(state) do
      %{
        sessions: Enum.reverse(state.sessions),
        runs: Enum.reverse(state.runs),
        tools: Enum.reverse(state.tools),
        llm: Enum.reverse(state.llm),
        errors: Enum.reverse(state.errors)
      }
    end

    defp broadcast(%{pubsub: nil}), do: :ok

    defp broadcast(%{pubsub: pubsub} = state) do
      Phoenix.PubSub.broadcast(pubsub, @topic, {:control_plane_update, snapshot(state)})
    end
  end
end
