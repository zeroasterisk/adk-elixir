defmodule ADK.EventTest do
  use ExUnit.Case, async: true
  doctest ADK.Event

  describe "new/1" do
    test "creates event with auto id and timestamp" do
      event = ADK.Event.new(%{author: "user", content: %{parts: [%{text: "hi"}]}})
      assert is_binary(event.id)
      assert %DateTime{} = event.timestamp
      assert event.author == "user"
    end
  end

  describe "text/1" do
    test "extracts text from content parts" do
      event = %ADK.Event{content: %{parts: [%{text: "hello"}]}}
      assert ADK.Event.text(event) == "hello"
    end

    test "returns nil for no content" do
      assert ADK.Event.text(%ADK.Event{}) == nil
    end

    test "returns nil for non-text parts" do
      event = %ADK.Event{content: %{parts: [%{function_call: %{}}]}}
      assert ADK.Event.text(event) == nil
    end
  end

  describe "final_response?/1" do
    test "true for non-partial event with content" do
      event = %ADK.Event{
        partial: false,
        content: %{parts: [%{text: "done"}]},
        actions: %ADK.EventActions{}
      }

      assert ADK.Event.final_response?(event)
    end

    test "false for partial event" do
      event = %ADK.Event{
        partial: true,
        content: %{parts: [%{text: "..."}]},
        actions: %ADK.EventActions{}
      }

      refute ADK.Event.final_response?(event)
    end

    test "false for event with transfer" do
      event = %ADK.Event{
        partial: false,
        content: %{parts: [%{text: "done"}]},
        actions: %ADK.EventActions{transfer_to_agent: "other"}
      }

      refute ADK.Event.final_response?(event)
    end
  end

  describe "error/2" do
    test "creates error event" do
      event = ADK.Event.error(:timeout, %{author: "bot"})
      assert event.error =~ "timeout"
      assert event.author == "bot"
    end
  end
end
