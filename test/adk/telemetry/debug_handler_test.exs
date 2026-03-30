defmodule ADK.Telemetry.DebugHandlerTest do
  use ExUnit.Case, async: false

  alias ADK.Telemetry.SpanStore
  alias ADK.Telemetry.DebugHandler

  setup do
    SpanStore.clear()

    # Ensure handler is attached (may already be from Application start)
    DebugHandler.attach()

    :ok
  end

  describe "telemetry event capture" do
    test "agent stop event is captured with session_id" do
      metadata = %{agent_name: "test_agent", session_id: "sess-debug-1", event_id: "evt-debug-1"}
      measurements = %{duration: 50_000_000, monotonic_time: System.monotonic_time(:nanosecond)}

      :telemetry.execute([:adk, :agent, :stop], measurements, metadata)

      # Give a moment for async processing (though it's synchronous in telemetry)
      assert {:ok, attrs} = SpanStore.get_event_span("evt-debug-1")
      assert attrs["agent_name"] == "test_agent"
      assert attrs["session_id"] == "sess-debug-1"

      spans = SpanStore.get_session_spans("sess-debug-1")
      assert length(spans) == 1
      assert hd(spans).name == "adk.agent.stop"
      assert hd(spans).duration_ms > 0
      assert is_binary(hd(spans).span_id)
      assert is_binary(hd(spans).trace_id)
    end

    test "tool stop event is captured" do
      metadata = %{tool_name: "calculator", agent_name: "math_agent", session_id: "sess-debug-2"}
      measurements = %{duration: 5_000_000, monotonic_time: System.monotonic_time(:nanosecond)}

      :telemetry.execute([:adk, :tool, :stop], measurements, metadata)

      spans = SpanStore.get_session_spans("sess-debug-2")
      assert length(spans) == 1
      assert hd(spans).name == "adk.tool.stop"
      assert hd(spans).attributes["tool_name"] == "calculator"
    end

    test "llm stop event is captured" do
      metadata = %{
        model: "gemini-flash-latest",
        agent_name: "llm_agent",
        session_id: "sess-debug-3"
      }

      measurements = %{duration: 100_000_000, monotonic_time: System.monotonic_time(:nanosecond)}

      :telemetry.execute([:adk, :llm, :stop], measurements, metadata)

      spans = SpanStore.get_session_spans("sess-debug-3")
      assert length(spans) == 1
      assert hd(spans).name == "adk.llm.stop"
      assert hd(spans).attributes["model"] == "gemini-flash-latest"
    end

    test "event without session_id only stores by event_id" do
      metadata = %{agent_name: "orphan", event_id: "evt-orphan"}
      measurements = %{duration: 1_000_000, monotonic_time: System.monotonic_time(:nanosecond)}

      :telemetry.execute([:adk, :agent, :stop], measurements, metadata)

      assert {:ok, attrs} = SpanStore.get_event_span("evt-orphan")
      assert attrs["agent_name"] == "orphan"
    end

    test "event without event_id uses span_id as fallback key" do
      metadata = %{agent_name: "no_event_id", session_id: "sess-debug-4"}
      measurements = %{duration: 1_000_000, monotonic_time: System.monotonic_time(:nanosecond)}

      :telemetry.execute([:adk, :agent, :stop], measurements, metadata)

      # Should still be stored in session spans
      spans = SpanStore.get_session_spans("sess-debug-4")
      assert length(spans) == 1
    end

    test "multiple events for same session accumulate" do
      base_meta = %{session_id: "sess-debug-5"}
      measurements = %{duration: 1_000_000, monotonic_time: System.monotonic_time(:nanosecond)}

      :telemetry.execute(
        [:adk, :agent, :stop],
        measurements,
        Map.put(base_meta, :agent_name, "a1")
      )

      :telemetry.execute([:adk, :tool, :stop], measurements, Map.put(base_meta, :tool_name, "t1"))
      :telemetry.execute([:adk, :llm, :stop], measurements, Map.put(base_meta, :model, "m1"))

      spans = SpanStore.get_session_spans("sess-debug-5")
      assert length(spans) == 3
    end
  end
end
