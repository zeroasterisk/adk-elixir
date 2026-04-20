defmodule ADK.Telemetry.ContractTest do
  use ExUnit.Case, async: true

  alias ADK.Telemetry.Contract

  setup do
    test_pid = self()

    handler_id = "contract-test-#{inspect(test_pid)}"

    :telemetry.attach_many(
      handler_id,
      Contract.all_events(),
      &__MODULE__.telemetry_handler/4,
      test_pid
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  def telemetry_handler(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  describe "all_events/0" do
    test "returns 14 events (3 runner + 3 agent + 3 tool + 3 llm + 2 session)" do
      events = Contract.all_events()
      assert length(events) == 14
    end

    test "includes runner events" do
      events = Contract.all_events()
      assert [:adk, :runner, :start] in events
      assert [:adk, :runner, :stop] in events
      assert [:adk, :runner, :exception] in events
    end

    test "includes agent events" do
      events = Contract.all_events()
      assert [:adk, :agent, :start] in events
      assert [:adk, :agent, :stop] in events
      assert [:adk, :agent, :exception] in events
    end

    test "includes tool events" do
      events = Contract.all_events()
      assert [:adk, :tool, :start] in events
      assert [:adk, :tool, :stop] in events
      assert [:adk, :tool, :exception] in events
    end

    test "includes llm events" do
      events = Contract.all_events()
      assert [:adk, :llm, :start] in events
      assert [:adk, :llm, :stop] in events
      assert [:adk, :llm, :exception] in events
    end

    test "includes session events" do
      events = Contract.all_events()
      assert [:adk, :session, :start] in events
      assert [:adk, :session, :stop] in events
    end
  end

  describe "stop_events/0" do
    test "returns 5 stop events" do
      stops = Contract.stop_events()
      assert length(stops) == 5

      for event <- stops do
        assert List.last(event) == :stop
      end
    end
  end

  describe "exception_events/0" do
    test "returns 4 exception events (no session exception)" do
      exceptions = Contract.exception_events()
      assert length(exceptions) == 4

      for event <- exceptions do
        assert List.last(event) == :exception
      end

      # Session has no exception event
      refute [:adk, :session, :exception] in exceptions
    end
  end

  describe "category accessors" do
    test "runner_events returns 3 events" do
      assert length(Contract.runner_events()) == 3
    end

    test "agent_events returns 3 events" do
      assert length(Contract.agent_events()) == 3
    end

    test "tool_events returns 3 events" do
      assert length(Contract.tool_events()) == 3
    end

    test "llm_events returns 3 events" do
      assert length(Contract.llm_events()) == 3
    end

    test "session_events returns 2 events" do
      assert length(Contract.session_events()) == 2
    end
  end

  describe "runner_span/2" do
    test "emits start/stop events with correct metadata" do
      meta = %{app_name: "testapp", agent_name: "bot", session_id: "s1", user_id: "u1"}
      result = Contract.runner_span(meta, fn -> :runner_done end)

      assert result == :runner_done

      assert_received {:telemetry_event, [:adk, :runner, :start], start_m, start_meta}
      assert start_meta.app_name == "testapp"
      assert start_meta.agent_name == "bot"
      assert start_meta.session_id == "s1"
      assert start_meta.user_id == "u1"
      assert is_integer(start_m.monotonic_time)
      assert is_integer(start_m.system_time)

      assert_received {:telemetry_event, [:adk, :runner, :stop], stop_m, stop_meta}
      assert stop_meta.app_name == "testapp"
      assert is_integer(stop_m.duration)
      assert stop_m.duration >= 0
    end

    test "emits exception event on raise" do
      meta = %{app_name: "testapp", agent_name: "bot", session_id: "s1", user_id: "u1"}

      assert_raise RuntimeError, "runner boom", fn ->
        Contract.runner_span(meta, fn -> raise "runner boom" end)
      end

      assert_received {:telemetry_event, [:adk, :runner, :start], _, start_meta}
      assert start_meta.app_name == "testapp"

      assert_received {:telemetry_event, [:adk, :runner, :exception], exc_m, exc_meta}
      assert is_integer(exc_m.duration)
      assert exc_meta.kind == :error
      assert %RuntimeError{message: "runner boom"} = exc_meta.reason
      assert is_list(exc_meta.stacktrace)
    end
  end

  describe "session_span/2" do
    test "emits start/stop events with correct metadata" do
      meta = %{app_name: "testapp", session_id: "sess-42", user_id: "u1"}
      result = Contract.session_span(meta, fn -> :session_ok end)

      assert result == :session_ok

      assert_received {:telemetry_event, [:adk, :session, :start], start_m, start_meta}
      assert start_meta.app_name == "testapp"
      assert start_meta.session_id == "sess-42"
      assert start_meta.user_id == "u1"
      assert is_integer(start_m.monotonic_time)
      assert is_integer(start_m.system_time)

      assert_received {:telemetry_event, [:adk, :session, :stop], stop_m, _stop_meta}
      assert is_integer(stop_m.duration)
    end
  end

  describe "agent_span/2" do
    test "emits start/stop events" do
      meta = %{agent_name: "helper", session_id: "s1", app_name: "app"}
      result = Contract.agent_span(meta, fn -> :agent_ok end)

      assert result == :agent_ok

      assert_received {:telemetry_event, [:adk, :agent, :start], _, start_meta}
      assert start_meta.agent_name == "helper"
      assert_received {:telemetry_event, [:adk, :agent, :stop], %{duration: d}, _stop_meta}
      assert is_integer(d)
    end
  end

  describe "tool_span/2" do
    test "emits start/stop events" do
      meta = %{tool_name: "search", agent_name: "bot", session_id: "s1"}
      result = Contract.tool_span(meta, fn -> :tool_ok end)

      assert result == :tool_ok

      assert_received {:telemetry_event, [:adk, :tool, :start], _, start_meta}
      assert start_meta.tool_name == "search"
      assert_received {:telemetry_event, [:adk, :tool, :stop], %{duration: _}, _stop_meta}
    end

    test "emits exception event on tool crash" do
      meta = %{tool_name: "bad_tool", agent_name: "bot", session_id: "s1"}

      assert_raise ArgumentError, fn ->
        Contract.tool_span(meta, fn -> raise ArgumentError, "bad arg" end)
      end

      assert_received {:telemetry_event, [:adk, :tool, :start], _, start_meta}
      assert start_meta.tool_name == "bad_tool"

      assert_received {:telemetry_event, [:adk, :tool, :exception], _, exc_meta}
      assert exc_meta.kind == :error
      assert %ArgumentError{} = exc_meta.reason
    end
  end

  describe "llm_span/2" do
    test "emits start/stop events with model metadata" do
      meta = %{model: "gemini-2.0-flash", agent_name: "bot", session_id: "s1"}
      result = Contract.llm_span(meta, fn -> :llm_ok end)

      assert result == :llm_ok

      assert_received {:telemetry_event, [:adk, :llm, :start], _, start_meta}
      assert start_meta.model == "gemini-2.0-flash"
      assert_received {:telemetry_event, [:adk, :llm, :stop], %{duration: _}, _stop_meta}
    end

    test "emits exception event on LLM failure" do
      meta = %{model: "gemini-2.0-flash", agent_name: "bot", session_id: "s1"}

      assert_raise RuntimeError, "api timeout", fn ->
        Contract.llm_span(meta, fn -> raise "api timeout" end)
      end

      assert_received {:telemetry_event, [:adk, :llm, :start], _, start_meta}
      assert start_meta.model == "gemini-2.0-flash"

      assert_received {:telemetry_event, [:adk, :llm, :exception], _, exc_meta}
      assert exc_meta.kind == :error
      assert exc_meta.reason.message == "api timeout"
    end
  end

  describe "metadata builders" do
    test "runner_metadata/3 builds correct map" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %ADK.Runner{app_name: "myapp", agent: agent}

      meta = Contract.runner_metadata(runner, "sess-1", "user-1")

      assert meta.app_name == "myapp"
      assert meta.agent_name == "bot"
      assert meta.session_id == "sess-1"
      assert meta.user_id == "user-1"
    end

    test "session_metadata/3 builds correct map" do
      meta = Contract.session_metadata("myapp", "sess-1", "user-1")

      assert meta.app_name == "myapp"
      assert meta.session_id == "sess-1"
      assert meta.user_id == "user-1"
    end

    test "agent_metadata/3 builds correct map" do
      meta = Contract.agent_metadata("bot", "sess-1", "myapp")

      assert meta.agent_name == "bot"
      assert meta.session_id == "sess-1"
      assert meta.app_name == "myapp"
    end

    test "tool_metadata/3 builds correct map" do
      meta = Contract.tool_metadata("search", "bot", "sess-1")

      assert meta.tool_name == "search"
      assert meta.agent_name == "bot"
      assert meta.session_id == "sess-1"
    end

    test "llm_metadata/3 builds correct map" do
      meta = Contract.llm_metadata("gemini-2.0-flash", "bot", "sess-1")

      assert meta.model == "gemini-2.0-flash"
      assert meta.agent_name == "bot"
      assert meta.session_id == "sess-1"
    end
  end

  describe "duration in measurements" do
    test "duration is non-negative for normal spans" do
      meta = %{agent_name: "test"}

      Contract.agent_span(meta, fn ->
        # Small sleep to get measurable duration
        Process.sleep(1)
        :ok
      end)

      assert_received {:telemetry_event, [:adk, :agent, :stop], %{duration: d}, _}
      assert d > 0
    end
  end
end
