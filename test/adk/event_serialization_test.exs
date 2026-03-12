defmodule ADK.EventSerializationTest do
  @moduledoc """
  Tests demonstrating event serialization for persistence, debugging, and replay.

  Events can be serialized to JSON and back, which is essential for:
  - Persisting conversation history to a database or file
  - Logging agent interactions for debugging
  - Replaying sessions for testing or evaluation
  - Sending events over the wire (A2A protocol, SSE streaming)
  """
  use ExUnit.Case, async: true

  alias ADK.Event
  alias ADK.EventActions

  describe "serializing agent responses for logging" do
    test "I can serialize an agent's response to JSON for structured logging" do
      event =
        Event.new(%{
          author: "support_agent",
          content: %{parts: [%{text: "Your order ships tomorrow."}]},
          partial: false
        })

      map = Event.to_map(event)

      assert map.author == "support_agent"
      assert map.content == %{parts: [%{text: "Your order ships tomorrow."}]}
      assert map.partial == false
      assert is_binary(map.timestamp), "timestamp is ISO 8601 for JSON compatibility"
      assert is_binary(map.id), "id is preserved for log correlation"
      assert map.actions.state_delta == %{}
    end

    test "nil timestamps are serialized safely" do
      event = %Event{author: "test", actions: %EventActions{}}
      map = Event.to_map(event)

      assert map.timestamp == nil
    end
  end

  describe "deserializing events from stored sessions" do
    test "I can reconstruct an event from a stored JSON object" do
      stored = %{
        "id" => "evt-2026-03-07-001",
        "author" => "user",
        "content" => %{"parts" => [%{"text" => "What's my order status?"}]},
        "timestamp" => "2026-03-07T08:00:00Z",
        "partial" => false,
        "actions" => %{
          "state_delta" => %{"last_query" => "order status"},
          "transfer_to_agent" => nil,
          "escalate" => false
        }
      }

      event = Event.from_map(stored)

      assert %Event{} = event
      assert event.id == "evt-2026-03-07-001"
      assert event.author == "user"
      assert event.actions.state_delta == %{"last_query" => "order status"}
      assert %DateTime{} = event.timestamp
    end

    test "from_map handles atom keys (useful when loading from Elixir term storage)" do
      map = %{id: "abc", author: "user", content: nil, timestamp: nil}
      event = Event.from_map(map)

      assert event.id == "abc"
      assert event.author == "user"
    end
  end

  describe "JSON roundtrip — events survive serialization intact" do
    test "a complete conversation event roundtrips through JSON encoding/decoding" do
      original =
        Event.new(%{
          author: "travel_agent",
          content: %{parts: [%{text: "I found 3 flights to New York."}]},
          actions: %EventActions{state_delta: %{"flights_found" => 3, "destination" => "NYC"}}
        })

      # Simulate writing to a database or log file
      json = original |> Event.to_map() |> Jason.encode!()

      # Simulate reading it back
      restored = json |> Jason.decode!() |> Event.from_map()

      assert restored.author == original.author
      assert restored.id == original.id
      assert restored.actions.state_delta == %{"flights_found" => 3, "destination" => "NYC"}
    end

    test "events with tool calls survive a JSON roundtrip" do
      original =
        Event.new(%{
          author: "agent",
          content: %{
            parts: [
              %{function_call: %{name: "book_flight", args: %{flight_id: "UA-1234"}}},
              %{text: "Booking your flight now..."}
            ]
          }
        })

      json = original |> Event.to_map() |> Jason.encode!()
      restored = json |> Jason.decode!() |> Event.from_map()

      # Content structure is preserved (keys become strings after JSON decode)
      [call_part, text_part] = restored.content["parts"]
      assert call_part["function_call"]["name"] == "book_flight"
      assert text_part["text"] == "Booking your flight now..."
    end

    test "state deltas with nested data survive the roundtrip" do
      original =
        Event.new(%{
          author: "agent",
          content: %{parts: [%{text: "Updated your preferences."}]},
          actions: %EventActions{
            state_delta: %{
              "preferences" => %{"theme" => "dark", "notifications" => true},
              "updated_at" => "2026-03-07T12:00:00Z"
            }
          }
        })

      json = original |> Event.to_map() |> Jason.encode!()
      restored = json |> Jason.decode!() |> Event.from_map()

      assert restored.actions.state_delta["preferences"]["theme"] == "dark"
    end
  end
end
