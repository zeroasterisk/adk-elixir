defmodule ADK.Phoenix.ControlLiveTest do
  use ExUnit.Case, async: true

  alias ADK.Phoenix.ControlLive
  alias ADK.Phoenix.ControlLive.Store

  # ── Store Tests ───────────────────────────────────────────────────────

  describe "Store" do
    setup do
      # Start a dedicated Store for each test (no PubSub needed for basic tests)
      name = :"store_#{System.unique_integer([:positive])}"
      {:ok, pid} = Store.start_link(name: name, pubsub: nil, max_events: 5)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{store: name}
    end

    test "starts with empty state", %{store: store} do
      state = Store.get_state(store)
      assert state.sessions == []
      assert state.runs == []
      assert state.tools == []
      assert state.llm == []
      assert state.errors == []
    end

    test "accumulates runner stop events", %{store: store} do
      # Simulate a telemetry event via GenServer cast
      GenServer.cast(
        store,
        {:telemetry_event, :runs,
         %{
           id: 1,
           phase: :stop,
           agent_name: "test_agent",
           session_id: "s1",
           user_id: "u1",
           app_name: "test_app",
           duration: 1234,
           status: :ok,
           timestamp: DateTime.utc_now()
         }}
      )

      # Give the cast time to process
      Process.sleep(10)

      state = Store.get_state(store)
      assert length(state.runs) == 1
      assert hd(state.runs).agent_name == "test_agent"
    end

    test "accumulates tool events", %{store: store} do
      GenServer.cast(
        store,
        {:telemetry_event, :tools,
         %{
           id: 1,
           phase: :stop,
           tool_name: "get_weather",
           agent_name: "weather_bot",
           session_id: "s1",
           duration: 500,
           status: :ok,
           timestamp: DateTime.utc_now()
         }}
      )

      Process.sleep(10)

      state = Store.get_state(store)
      assert length(state.tools) == 1
      assert hd(state.tools).tool_name == "get_weather"
    end

    test "accumulates LLM events", %{store: store} do
      GenServer.cast(
        store,
        {:telemetry_event, :llm,
         %{
           id: 1,
           phase: :stop,
           model: "gemini-2.0-flash",
           agent_name: "bot",
           session_id: "s1",
           duration: 2000,
           input_tokens: 100,
           output_tokens: 50,
           status: :ok,
           timestamp: DateTime.utc_now()
         }}
      )

      Process.sleep(10)

      state = Store.get_state(store)
      assert length(state.llm) == 1
      assert hd(state.llm).model == "gemini-2.0-flash"
    end

    test "ring buffer respects max_events", %{store: store} do
      for i <- 1..10 do
        GenServer.cast(
          store,
          {:telemetry_event, :runs,
           %{
             id: i,
             phase: :stop,
             agent_name: "agent_#{i}",
             session_id: "s1",
             duration: i * 100,
             status: :ok,
             timestamp: DateTime.utc_now()
           }}
        )
      end

      Process.sleep(50)

      state = Store.get_state(store)
      # max_events is 5, so only 5 most recent should remain
      assert length(state.runs) == 5
    end

    test "ring buffer keeps most recent events", %{store: store} do
      for i <- 1..10 do
        GenServer.cast(
          store,
          {:telemetry_event, :tools,
           %{
             id: i,
             phase: :stop,
             tool_name: "tool_#{i}",
             agent_name: "bot",
             session_id: "s1",
             duration: i * 10,
             status: :ok,
             timestamp: DateTime.utc_now()
           }}
        )
      end

      Process.sleep(50)

      state = Store.get_state(store)
      assert length(state.tools) == 5
      # Most recent should be tool_10 (returned in chronological order by get_state)
      tool_names = Enum.map(state.tools, & &1.tool_name)
      assert "tool_10" in tool_names
      refute "tool_1" in tool_names
    end

    test "clear resets all buffers", %{store: store} do
      GenServer.cast(
        store,
        {:telemetry_event, :runs,
         %{
           id: 1,
           phase: :stop,
           agent_name: "a",
           session_id: "s",
           duration: 100,
           status: :ok,
           timestamp: DateTime.utc_now()
         }}
      )

      Process.sleep(10)
      assert length(Store.get_state(store).runs) == 1

      Store.clear(store)
      state = Store.get_state(store)
      assert state.runs == []
      assert state.tools == []
      assert state.llm == []
    end

    test "accumulates session events", %{store: store} do
      GenServer.cast(
        store,
        {:telemetry_event, :sessions,
         %{
           id: 1,
           phase: :start,
           session_id: "sess-123",
           user_id: "user-1",
           app_name: "myapp",
           duration: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      Process.sleep(10)

      state = Store.get_state(store)
      assert length(state.sessions) == 1
      assert hd(state.sessions).session_id == "sess-123"
    end

    test "accumulates error events", %{store: store} do
      GenServer.cast(
        store,
        {:telemetry_event, :errors,
         %{
           id: 1,
           phase: :exception,
           category: :tool,
           tool_name: "bad_tool",
           agent_name: "bot",
           session_id: "s1",
           duration: 50,
           status: :error,
           timestamp: DateTime.utc_now()
         }}
      )

      Process.sleep(10)

      state = Store.get_state(store)
      assert length(state.errors) == 1
      assert hd(state.errors).category == :tool
    end
  end

  # ── Store with PubSub Tests ───────────────────────────────────────────

  describe "Store with PubSub" do
    setup do
      pubsub_name = :"pubsub_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Phoenix.PubSub.Supervisor.start_link(name: pubsub_name, adapter: Phoenix.PubSub.PG2)

      store_name = :"store_ps_#{System.unique_integer([:positive])}"
      {:ok, pid} = Store.start_link(name: store_name, pubsub: pubsub_name, max_events: 10)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{store: store_name, pubsub: pubsub_name}
    end

    test "broadcasts on new events", %{store: store, pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, Store.topic())

      GenServer.cast(
        store,
        {:telemetry_event, :runs,
         %{
           id: 1,
           phase: :stop,
           agent_name: "bot",
           session_id: "s1",
           duration: 100,
           status: :ok,
           timestamp: DateTime.utc_now()
         }}
      )

      assert_receive {:control_plane_update, state}, 1000
      assert length(state.runs) == 1
    end
  end

  # ── Telemetry Integration Tests ───────────────────────────────────────

  describe "telemetry integration" do
    setup do
      store_name = :"store_telem_#{System.unique_integer([:positive])}"
      {:ok, pid} = Store.start_link(name: store_name, pubsub: nil, max_events: 20)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{store: store_name}
    end

    test "handles telemetry handler callback for runner events", %{store: store} do
      Store.handle_telemetry_event(
        [:adk, :runner, :stop],
        %{duration: 5_000_000, monotonic_time: 0},
        %{agent_name: "main_agent", session_id: "s1", user_id: "u1", app_name: "app"},
        %{server: store}
      )

      Process.sleep(20)

      state = Store.get_state(store)
      assert length(state.runs) == 1
      assert hd(state.runs).agent_name == "main_agent"
    end

    test "handles telemetry handler callback for tool events", %{store: store} do
      Store.handle_telemetry_event(
        [:adk, :tool, :stop],
        %{duration: 1_000_000, monotonic_time: 0},
        %{tool_name: "search", agent_name: "bot", session_id: "s1"},
        %{server: store}
      )

      Process.sleep(20)

      state = Store.get_state(store)
      assert length(state.tools) == 1
      assert hd(state.tools).tool_name == "search"
    end

    test "handles telemetry handler callback for llm events", %{store: store} do
      Store.handle_telemetry_event(
        [:adk, :llm, :stop],
        %{duration: 3_000_000, monotonic_time: 0},
        %{model: "gemini-2.0-flash", agent_name: "bot", session_id: "s1"},
        %{server: store}
      )

      Process.sleep(20)

      state = Store.get_state(store)
      assert length(state.llm) == 1
      assert hd(state.llm).model == "gemini-2.0-flash"
    end

    test "handles telemetry handler callback for exception events", %{store: store} do
      Store.handle_telemetry_event(
        [:adk, :tool, :exception],
        %{duration: 100_000, monotonic_time: 0},
        %{tool_name: "fail_tool", agent_name: "bot", session_id: "s1"},
        %{server: store}
      )

      Process.sleep(20)

      state = Store.get_state(store)
      assert length(state.errors) == 1
      assert hd(state.errors).category == :tool
    end

    test "handles telemetry handler callback for session events", %{store: store} do
      Store.handle_telemetry_event(
        [:adk, :session, :start],
        %{monotonic_time: 0, system_time: 0},
        %{session_id: "s-new", user_id: "u1", app_name: "app"},
        %{server: store}
      )

      Process.sleep(20)

      state = Store.get_state(store)
      assert length(state.sessions) == 1
      assert hd(state.sessions).session_id == "s-new"
    end
  end

  # ── LiveView Render Tests ─────────────────────────────────────────────

  describe "LiveView render" do
    test "renders all sections with empty data" do
      assigns = %{
        sessions: [],
        runs: [],
        tools: [],
        llm: [],
        errors: [],
        beam: beam_fixture(),
        page_title: "Test"
      }

      html = Phoenix.LiveViewTest.rendered_to_string(ControlLive.render(assigns))

      assert html =~ "System Health"
      assert html =~ "Active Sessions"
      assert html =~ "Recent Agent Runs"
      assert html =~ "Tool Call Log"
      assert html =~ "LLM Metrics"
      assert html =~ "Recent Errors"
    end

    test "renders BEAM metrics with process count and memory" do
      assigns = %{
        sessions: [],
        runs: [],
        tools: [],
        llm: [],
        errors: [],
        beam: beam_fixture(),
        page_title: "Test"
      }

      html = Phoenix.LiveViewTest.rendered_to_string(ControlLive.render(assigns))

      assert html =~ "Processes"
      assert html =~ "Memory"
      assert html =~ "42"
      assert html =~ "10.0 MB"
    end

    test "renders session data" do
      assigns = %{
        sessions: [
          %{
            session_id: "sess-abc",
            user_id: "alice",
            app_name: "myapp",
            phase: :start,
            timestamp: ~U[2026-03-18 00:00:00Z]
          }
        ],
        runs: [],
        tools: [],
        llm: [],
        errors: [],
        beam: beam_fixture(),
        page_title: "Test"
      }

      html = Phoenix.LiveViewTest.rendered_to_string(ControlLive.render(assigns))

      assert html =~ "sess-abc"
      assert html =~ "alice"
      assert html =~ "myapp"
    end

    test "renders run data" do
      assigns = %{
        sessions: [],
        runs: [
          %{
            agent_name: "weather_bot",
            phase: :stop,
            status: :ok,
            duration: 1_500_000,
            timestamp: ~U[2026-03-18 00:00:00Z]
          }
        ],
        tools: [],
        llm: [],
        errors: [],
        beam: beam_fixture(),
        page_title: "Test"
      }

      html = Phoenix.LiveViewTest.rendered_to_string(ControlLive.render(assigns))

      assert html =~ "weather_bot"
    end

    test "renders tool data" do
      assigns = %{
        sessions: [],
        runs: [],
        tools: [
          %{
            tool_name: "get_weather",
            agent_name: "bot",
            status: :ok,
            duration: 500_000,
            timestamp: ~U[2026-03-18 00:00:00Z]
          }
        ],
        llm: [],
        errors: [],
        beam: beam_fixture(),
        page_title: "Test"
      }

      html = Phoenix.LiveViewTest.rendered_to_string(ControlLive.render(assigns))

      assert html =~ "get_weather"
    end

    test "renders LLM data" do
      assigns = %{
        sessions: [],
        runs: [],
        tools: [],
        llm: [
          %{
            model: "gemini-2.0-flash",
            agent_name: "bot",
            status: :ok,
            duration: 2_000_000,
            input_tokens: 150,
            output_tokens: 75,
            timestamp: ~U[2026-03-18 00:00:00Z]
          }
        ],
        errors: [],
        beam: beam_fixture(),
        page_title: "Test"
      }

      html = Phoenix.LiveViewTest.rendered_to_string(ControlLive.render(assigns))

      assert html =~ "gemini-2.0-flash"
      assert html =~ "150"
      assert html =~ "75"
    end

    test "renders error data" do
      assigns = %{
        sessions: [],
        runs: [],
        tools: [],
        llm: [],
        errors: [
          %{
            category: :tool,
            tool_name: "bad_tool",
            agent_name: "bot",
            timestamp: ~U[2026-03-18 00:00:00Z]
          }
        ],
        beam: beam_fixture(),
        page_title: "Test"
      }

      html = Phoenix.LiveViewTest.rendered_to_string(ControlLive.render(assigns))

      assert html =~ "bad_tool"
      assert html =~ "tool"
    end

    test "renders empty state messages" do
      assigns = %{
        sessions: [],
        runs: [],
        tools: [],
        llm: [],
        errors: [],
        beam: beam_fixture(),
        page_title: "Test"
      }

      html = Phoenix.LiveViewTest.rendered_to_string(ControlLive.render(assigns))

      assert html =~ "No session events yet"
      assert html =~ "No agent runs yet"
      assert html =~ "No tool calls yet"
      assert html =~ "No LLM calls yet"
      assert html =~ "No errors"
    end
  end

  # ── Format Helpers Tests ──────────────────────────────────────────────

  describe "format_bytes/1" do
    test "formats bytes" do
      assert ControlLive.format_bytes(500) == "500 B"
      assert ControlLive.format_bytes(1024) == "1.0 KB"
      assert ControlLive.format_bytes(1_048_576) == "1.0 MB"
      assert ControlLive.format_bytes(1_073_741_824) == "1.0 GB"
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp beam_fixture do
    %{
      process_count: 42,
      memory_human: "10.0 MB",
      memory_total: 10_485_760,
      atom_count: 1000,
      port_count: 5,
      schedulers: 8,
      schedulers_online: 8,
      uptime_human: "1h 30m",
      memory_detail: [
        {"Processes", 5_000_000},
        {"Binary", 2_000_000},
        {"ETS", 1_000_000},
        {"Atom", 500_000},
        {"Code", 1_000_000},
        {"System", 985_760}
      ]
    }
  end
end
