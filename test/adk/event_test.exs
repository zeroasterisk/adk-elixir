defmodule ADK.EventTest do
  @moduledoc """
  Tests demonstrating how developers work with ADK Events.

  Events are the core data structure in ADK — every message, tool call,
  LLM response, and state change flows through the system as an Event.
  These tests show how to create, inspect, pattern match, and filter events
  in real agent scenarios.
  """
  use ExUnit.Case, async: true
  doctest ADK.Event

  alias ADK.Event
  alias ADK.EventActions

  describe "creating events" do
    test "create a user message event with auto-generated id and timestamp" do
      event = Event.new(%{author: "user", content: %{parts: [%{text: "What's the weather?"}]}})

      assert is_binary(event.id), "every event gets a unique id"
      assert %DateTime{} = event.timestamp, "events are timestamped automatically"
      assert event.author == "user"
    end

    test "create an agent response event" do
      event =
        Event.new(%{
          author: "weather_agent",
          content: %{parts: [%{text: "It's 72°F and sunny in Louisville."}]}
        })

      assert event.author == "weather_agent"
      assert Event.text(event) == "It's 72°F and sunny in Louisville."
    end

    test "create an error event when something goes wrong" do
      event = Event.error(:timeout, %{author: "weather_agent"})

      assert event.error =~ "timeout"
      assert event.author == "weather_agent"
    end
  end

  describe "reading event content" do
    test "extract the text from a simple message" do
      event = %Event{content: %{parts: [%{text: "Hello from the agent!"}]}}

      assert Event.text(event) == "Hello from the agent!"
    end

    test "text returns nil when the event has no content" do
      assert Event.text(%Event{}) == nil
    end

    test "text returns nil for tool-call-only events (no text part)" do
      event = %Event{
        content: %{parts: [%{function_call: %{name: "get_weather", args: %{city: "Louisville"}}}]}
      }

      assert Event.text(event) == nil
    end
  end

  describe "detecting final responses" do
    test "a complete text response is a final response" do
      event = %Event{
        partial: false,
        content: %{parts: [%{text: "Here's your answer."}]},
        actions: %EventActions{}
      }

      assert Event.final_response?(event)
    end

    test "a streaming chunk (partial) is not a final response" do
      event = %Event{
        partial: true,
        content: %{parts: [%{text: "Still generating..."}]},
        actions: %EventActions{}
      }

      refute Event.final_response?(event)
    end

    test "an event that transfers to another agent is not final" do
      event = %Event{
        partial: false,
        content: %{parts: [%{text: "Let me hand you off to the booking agent."}]},
        actions: %EventActions{transfer_to_agent: "booking_agent"}
      }

      refute Event.final_response?(event)
    end
  end

  describe "pattern matching on events" do
    test "match on author to filter user vs agent messages" do
      events = [
        Event.new(%{author: "user", content: %{parts: [%{text: "Book a flight"}]}}),
        Event.new(%{author: "travel_agent", content: %{parts: [%{text: "Sure! Where to?"}]}}),
        Event.new(%{author: "user", content: %{parts: [%{text: "New York"}]}})
      ]

      user_messages = Enum.filter(events, &(&1.author == "user"))
      assert length(user_messages) == 2
    end

    test "find the final response in a conversation" do
      events = [
        Event.new(%{author: "user", content: %{parts: [%{text: "Summarize this doc"}]}}),
        Event.new(%{
          author: "summarizer",
          content: %{
            parts: [%{function_call: %{name: "read_doc", args: %{id: "doc-123"}}}]
          }
        }),
        Event.new(%{
          author: "summarizer",
          content: %{parts: [%{text: "The document discusses Elixir's OTP patterns."}]}
        })
      ]

      final =
        events
        |> Enum.filter(&(&1.author != "user"))
        |> Enum.find(&Event.final_response?/1)

      assert Event.text(final) =~ "OTP patterns"
    end

    test "separate tool-calling events from text events" do
      events = [
        Event.new(%{
          author: "agent",
          content: %{parts: [%{function_call: %{name: "search", args: %{q: "ADK"}}}]}
        }),
        Event.new(%{author: "agent", content: %{parts: [%{text: "Found 3 results."}]}})
      ]

      {tool_events, text_events} = Enum.split_with(events, &Event.has_function_calls?/1)
      assert length(tool_events) == 1
      assert length(text_events) == 1
    end
  end

  describe "filtering events by branch" do
    test "events without a branch belong to every branch" do
      event = %Event{branch: nil}
      assert Event.on_branch?(event, "root.router.weather")
    end

    test "events on a parent branch are visible to child agents" do
      event = %Event{branch: "root"}
      assert Event.on_branch?(event, "root.router.weather")
    end

    test "events from a sibling branch are NOT visible" do
      event = %Event{branch: "root.router.news"}
      refute Event.on_branch?(event, "root.router.weather")
    end
  end
end
