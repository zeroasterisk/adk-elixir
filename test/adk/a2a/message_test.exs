defmodule ADK.A2A.MessageTest do
  use ExUnit.Case, async: true

  alias ADK.A2A.Message

  describe "from_event/1" do
    test "converts a user event to an A2A message" do
      event = ADK.Event.new(%{author: "user", content: %{parts: [%{text: "hello"}]}})
      msg = Message.from_event(event)

      assert msg["role"] == "user"
      assert [%{"type" => "text", "text" => "hello"}] = msg["parts"]
    end

    test "converts an agent event to an A2A message" do
      event = ADK.Event.new(%{author: "my_agent", content: %{parts: [%{text: "hi back"}]}})
      msg = Message.from_event(event)

      assert msg["role"] == "agent"
      assert [%{"type" => "text", "text" => "hi back"}] = msg["parts"]
    end

    test "handles error events" do
      event = ADK.Event.new(%{author: "agent", error: "boom", content: nil})
      msg = Message.from_event(event)

      assert msg["role"] == "agent"
      assert [%{"type" => "text", "text" => "Error: boom"}] = msg["parts"]
    end
  end

  describe "to_event/1" do
    test "converts an A2A message to an ADK event" do
      msg = %{"role" => "user", "parts" => [%{"type" => "text", "text" => "hello"}]}
      event = Message.to_event(msg)

      assert event.author == "user"
      assert %{parts: [%{text: "hello"}]} = event.content
    end

    test "converts agent message to event" do
      msg = %{"role" => "agent", "parts" => [%{"type" => "text", "text" => "response"}]}
      event = Message.to_event(msg)

      assert event.author == "agent"
      assert %{parts: [%{text: "response"}]} = event.content
    end
  end

  describe "roundtrip" do
    test "event -> message -> event preserves content" do
      original = ADK.Event.new(%{author: "user", content: %{parts: [%{text: "test"}]}})
      roundtripped = original |> Message.from_event() |> Message.to_event()

      assert roundtripped.author == "user"
      assert ADK.Event.text(roundtripped) == "test"
    end
  end
end
