defmodule ADK.EventStructureTest do
  @moduledoc """
  Tests demonstrating how to work with the Gemini Content/Part structure in events.

  When your agent makes tool calls or receives tool results, they live inside
  `event.content.parts` as Gemini-style `function_call` and `function_response`
  parts. These tests show how to extract, inspect, and work with them.
  """
  use ExUnit.Case, async: true

  alias ADK.Event

  describe "extracting tool calls from agent events" do
    test "when my agent decides to call a tool, I can extract the call details" do
      # Simulate an LLM response where the agent wants to search and fetch
      event =
        Event.new(%{
          author: "research_agent",
          content: %{
            parts: [
              %{function_call: %{name: "web_search", args: %{query: "Elixir ADK examples"}}},
              %{text: "Let me search for that..."},
              %{function_call: %{name: "fetch_url", args: %{url: "https://hex.pm/packages/adk"}}}
            ]
          }
        })

      calls = Event.function_calls(event)

      assert length(calls) == 2
      assert Enum.at(calls, 0).name == "web_search"
      assert Enum.at(calls, 0).args == %{query: "Elixir ADK examples"}
      assert Enum.at(calls, 1).name == "fetch_url"
    end

    test "a plain text response has no tool calls" do
      event =
        Event.new(%{
          author: "chat_agent",
          content: %{parts: [%{text: "I don't need any tools for this."}]}
        })

      assert Event.function_calls(event) == []
    end

    test "an event with nil content has no tool calls" do
      event = Event.new(%{author: "agent", content: nil})
      assert Event.function_calls(event) == []
    end
  end

  describe "extracting tool results from events" do
    test "after a tool runs, I can extract its result from the response event" do
      event =
        Event.new(%{
          author: "tool_executor",
          content: %{
            parts: [
              %{
                function_response: %{
                  name: "web_search",
                  response: %{results: ["result 1", "result 2", "result 3"]}
                }
              }
            ]
          }
        })

      responses = Event.function_responses(event)
      assert length(responses) == 1
      assert hd(responses).name == "web_search"
      assert hd(responses).response.results == ["result 1", "result 2", "result 3"]
    end

    test "a text-only event has no tool results" do
      event = Event.new(%{author: "agent", content: %{parts: [%{text: "hi"}]}})
      assert Event.function_responses(event) == []
    end
  end

  describe "checking if an event involves tool use" do
    test "quickly check if the agent wants to call a tool" do
      tool_call_event =
        Event.new(%{
          author: "agent",
          content: %{
            parts: [%{function_call: %{name: "get_weather", args: %{city: "Louisville"}}}]
          }
        })

      assert Event.has_function_calls?(tool_call_event)
      refute Event.has_function_responses?(tool_call_event)
    end

    test "quickly check if an event contains a tool result" do
      tool_result_event =
        Event.new(%{
          author: "tool",
          content: %{
            parts: [
              %{function_response: %{name: "get_weather", response: %{temp: 72, unit: "F"}}}
            ]
          }
        })

      refute Event.has_function_calls?(tool_result_event)
      assert Event.has_function_responses?(tool_result_event)
    end
  end

  describe "Gemini Content/Part structure" do
    test "tool calls live in content.parts, not as top-level event fields" do
      # ADK follows Gemini's Content/Part structure — function_calls and
      # function_responses are NOT top-level fields on the Event struct
      refute Map.has_key?(%Event{}, :function_calls)
      refute Map.has_key?(%Event{}, :function_responses)
    end

    test "an event with tool calls is not considered a final response" do
      event =
        Event.new(%{
          author: "agent",
          content: %{
            parts: [%{function_call: %{name: "lookup_order", args: %{order_id: "ORD-4521"}}}]
          }
        })

      refute Event.final_response?(event),
             "the agent still needs to process the tool result before responding"
    end

    test "after tool processing, the agent's text reply IS a final response" do
      event =
        Event.new(%{
          author: "support_agent",
          content: %{parts: [%{text: "Order ORD-4521 shipped on March 10th."}]}
        })

      assert Event.final_response?(event)
    end
  end

  describe "roundtripping events with tool calls through serialization" do
    test "tool calls survive a to_map/from_map roundtrip" do
      original =
        Event.new(%{
          author: "agent",
          content: %{
            parts: [%{function_call: %{name: "calculate", args: %{expression: "2 + 2"}}}]
          }
        })

      roundtripped = original |> Event.to_map() |> Event.from_map()
      assert Event.function_calls(roundtripped) == Event.function_calls(original)
    end

    test "legacy events with top-level function_calls are migrated into content.parts" do
      # Old format had function_calls as a top-level field — from_map migrates them
      legacy_map = %{
        "id" => "legacy-evt-1",
        "author" => "agent",
        "content" => nil,
        "function_calls" => [%{name: "search", args: %{q: "test"}}],
        "function_responses" => nil
      }

      event = Event.from_map(legacy_map)
      assert length(Event.function_calls(event)) == 1
      assert hd(Event.function_calls(event)).name == "search"
    end

    test "legacy function_responses are merged into existing content.parts" do
      legacy_map = %{
        "id" => "legacy-evt-2",
        "author" => "agent",
        "content" => %{"parts" => [%{"text" => "processing..."}]},
        "function_responses" => [%{name: "search", response: %{result: "found it"}}]
      }

      event = Event.from_map(legacy_map)
      assert length(Event.function_responses(event)) == 1
    end
  end
end
