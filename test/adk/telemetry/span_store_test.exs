defmodule ADK.Telemetry.SpanStoreTest do
  use ExUnit.Case, async: false

  alias ADK.Telemetry.SpanStore

  setup do
    # Clear any existing data between tests
    SpanStore.clear()
    :ok
  end

  describe "event spans" do
    test "put and get event span" do
      attrs = %{"agent_name" => "test_agent", "duration_ms" => 42.0}
      assert :ok = SpanStore.put_event_span("evt-1", attrs)
      assert {:ok, ^attrs} = SpanStore.get_event_span("evt-1")
    end

    test "get_event_span returns :not_found for missing key" do
      assert :not_found = SpanStore.get_event_span("nonexistent")
    end

    test "overwriting an event span replaces the previous value" do
      SpanStore.put_event_span("evt-2", %{"v" => 1})
      SpanStore.put_event_span("evt-2", %{"v" => 2})
      assert {:ok, %{"v" => 2}} = SpanStore.get_event_span("evt-2")
    end
  end

  describe "session spans" do
    test "put and get session spans" do
      span1 = %{name: "adk.agent.stop", duration_ms: 10.0}
      span2 = %{name: "adk.tool.stop", duration_ms: 5.0}

      SpanStore.put_session_span("sess-1", span1)
      SpanStore.put_session_span("sess-1", span2)

      spans = SpanStore.get_session_spans("sess-1")
      assert length(spans) == 2
      assert Enum.at(spans, 0) == span1
      assert Enum.at(spans, 1) == span2
    end

    test "get_session_spans returns empty list for missing session" do
      assert [] = SpanStore.get_session_spans("nonexistent")
    end

    test "different sessions are independent" do
      SpanStore.put_session_span("sess-a", %{name: "a"})
      SpanStore.put_session_span("sess-b", %{name: "b"})

      assert [%{name: "a"}] = SpanStore.get_session_spans("sess-a")
      assert [%{name: "b"}] = SpanStore.get_session_spans("sess-b")
    end
  end

  describe "clear/0" do
    test "clears all data" do
      SpanStore.put_event_span("evt-x", %{"a" => 1})
      SpanStore.put_session_span("sess-x", %{b: 2})

      SpanStore.clear()

      assert :not_found = SpanStore.get_event_span("evt-x")
      assert [] = SpanStore.get_session_spans("sess-x")
    end
  end
end
