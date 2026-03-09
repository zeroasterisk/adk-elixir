defmodule ADK.EventStructureTest do
  use ExUnit.Case, async: true

  alias ADK.Event

  describe "function_calls/1" do
    test "extracts function calls from content parts" do
      event = Event.new(%{
        author: "agent",
        content: %{parts: [
          %{function_call: %{name: "search", args: %{q: "hello"}}},
          %{text: "thinking..."},
          %{function_call: %{name: "fetch", args: %{url: "http://example.com"}}}
        ]}
      })

      calls = Event.function_calls(event)
      assert length(calls) == 2
      assert Enum.at(calls, 0).name == "search"
      assert Enum.at(calls, 1).name == "fetch"
    end

    test "returns empty list when no function calls" do
      event = Event.new(%{author: "agent", content: %{parts: [%{text: "hi"}]}})
      assert Event.function_calls(event) == []
    end

    test "returns empty list when content is nil" do
      event = Event.new(%{author: "agent", content: nil})
      assert Event.function_calls(event) == []
    end
  end

  describe "function_responses/1" do
    test "extracts function responses from content parts" do
      event = Event.new(%{
        author: "agent",
        content: %{parts: [
          %{function_response: %{name: "search", response: %{results: ["a", "b"]}}}
        ]}
      })

      responses = Event.function_responses(event)
      assert length(responses) == 1
      assert hd(responses).name == "search"
    end

    test "returns empty list when no function responses" do
      event = Event.new(%{author: "agent", content: %{parts: [%{text: "hi"}]}})
      assert Event.function_responses(event) == []
    end
  end

  describe "has_function_calls?/1 and has_function_responses?/1" do
    test "detects function calls" do
      event = Event.new(%{
        author: "agent",
        content: %{parts: [%{function_call: %{name: "foo", args: %{}}}]}
      })

      assert Event.has_function_calls?(event)
      refute Event.has_function_responses?(event)
    end

    test "detects function responses" do
      event = Event.new(%{
        author: "agent",
        content: %{parts: [%{function_response: %{name: "foo", response: %{}}}]}
      })

      refute Event.has_function_calls?(event)
      assert Event.has_function_responses?(event)
    end
  end

  describe "no top-level function_calls/function_responses fields" do
    test "Event struct does not have function_calls field" do
      refute Map.has_key?(%Event{}, :function_calls)
    end

    test "Event struct does not have function_responses field" do
      refute Map.has_key?(%Event{}, :function_responses)
    end
  end

  describe "to_map/from_map roundtrip" do
    test "roundtrips event with function calls in content.parts" do
      event = Event.new(%{
        author: "agent",
        content: %{parts: [
          %{function_call: %{name: "search", args: %{q: "test"}}}
        ]}
      })

      roundtripped = event |> Event.to_map() |> Event.from_map()
      assert Event.function_calls(roundtripped) == Event.function_calls(event)
    end

    test "from_map migrates legacy function_calls into content.parts" do
      legacy_map = %{
        "id" => "test-1",
        "author" => "agent",
        "content" => nil,
        "function_calls" => [%{name: "search", args: %{q: "test"}}],
        "function_responses" => nil
      }

      event = Event.from_map(legacy_map)
      assert length(Event.function_calls(event)) == 1
      assert hd(Event.function_calls(event)).name == "search"
    end

    test "from_map migrates legacy function_responses into content.parts" do
      legacy_map = %{
        "id" => "test-2",
        "author" => "agent",
        "content" => %{"parts" => [%{"text" => "existing"}]},
        "function_responses" => [%{name: "search", response: %{result: "ok"}}]
      }

      event = Event.from_map(legacy_map)
      assert length(Event.function_responses(event)) == 1
    end
  end

  describe "final_response?" do
    test "event with function calls is not final" do
      event = Event.new(%{
        author: "agent",
        content: %{parts: [%{function_call: %{name: "foo", args: %{}}}]}
      })

      refute Event.final_response?(event)
    end

    test "event with only text is final" do
      event = Event.new(%{
        author: "agent",
        content: %{parts: [%{text: "done"}]}
      })

      assert Event.final_response?(event)
    end
  end
end
