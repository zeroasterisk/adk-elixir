defmodule ADK.EventSerializationTest do
  use ExUnit.Case, async: true

  test "to_map/1 produces a serializable map" do
    event = ADK.Event.new(%{
      author: "agent",
      content: %{parts: [%{text: "Hello!"}]},
      partial: false
    })

    map = ADK.Event.to_map(event)
    assert map.author == "agent"
    assert map.content == %{parts: [%{text: "Hello!"}]}
    assert map.partial == false
    assert is_binary(map.timestamp)
    assert is_binary(map.id)
    assert map.actions.state_delta == %{}
  end

  test "from_map/1 reconstructs an Event" do
    map = %{
      "id" => "test123",
      "author" => "user",
      "content" => %{"parts" => [%{"text" => "hi"}]},
      "timestamp" => "2026-03-07T08:00:00Z",
      "partial" => false,
      "actions" => %{
        "state_delta" => %{"key" => "value"},
        "transfer_to_agent" => nil,
        "escalate" => false
      }
    }

    event = ADK.Event.from_map(map)
    assert %ADK.Event{} = event
    assert event.id == "test123"
    assert event.author == "user"
    assert event.actions.state_delta == %{"key" => "value"}
    assert %DateTime{} = event.timestamp
  end

  test "roundtrip to_map -> JSON -> from_map" do
    original = ADK.Event.new(%{
      author: "bot",
      content: %{parts: [%{text: "Round trip!"}]},
      actions: %ADK.EventActions{state_delta: %{"count" => 42}}
    })

    json = original |> ADK.Event.to_map() |> Jason.encode!()
    decoded = json |> Jason.decode!() |> ADK.Event.from_map()

    assert decoded.author == original.author
    assert decoded.id == original.id
    assert decoded.content == %{"parts" => [%{"text" => "Round trip!"}]}
    assert decoded.actions.state_delta == %{"count" => 42}
  end

  test "from_map handles atom keys" do
    map = %{id: "abc", author: "user", content: nil, timestamp: nil}
    event = ADK.Event.from_map(map)
    assert event.id == "abc"
    assert event.author == "user"
  end

  test "to_map handles nil timestamp" do
    event = %ADK.Event{author: "test", actions: %ADK.EventActions{}}
    map = ADK.Event.to_map(event)
    assert map.timestamp == nil
  end
end
