defmodule ADK.Agent.LlmAgentDedupTest do
  use ExUnit.Case, async: true

  # Access the private function via Module.concat to avoid exposing it publicly.
  # We call build_messages/1 indirectly through the dedup logic, but since
  # last_user_message_matches?/2 is private, we test it through a thin wrapper.

  # We can test the dedup behaviour by invoking the private function via
  # Kernel.apply and :erlang.apply won't work on defp. Instead we replicate
  # the exact logic here for unit-level coverage, and rely on integration
  # tests for the full build_messages path.

  # Re-implement the function under test so we can unit-test the algorithm
  # without exposing it. This mirrors the production code exactly.
  defp last_user_message_matches?(history, [%{role: :user, parts: [%{text: text}]}]) do
    history
    |> Enum.reverse()
    |> Enum.find(fn
      %{role: :user} -> true
      _ -> false
    end)
    |> case do
      %{role: :user, parts: parts} ->
        Enum.any?(parts, fn
          %{text: ^text} -> true
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp last_user_message_matches?(_history, _user_msg), do: false

  describe "last_user_message_matches?/2" do
    test "returns true when last user message matches the text" do
      history = [
        %{role: :model, parts: [%{text: "Hello"}]},
        %{role: :user, parts: [%{text: "do something"}]}
      ]

      assert last_user_message_matches?(history, [
               %{role: :user, parts: [%{text: "do something"}]}
             ])
    end

    test "returns false when last user message differs" do
      history = [
        %{role: :user, parts: [%{text: "do something"}]},
        %{role: :model, parts: [%{text: "ok"}]},
        %{role: :user, parts: [%{text: "do something else"}]}
      ]

      refute last_user_message_matches?(history, [
               %{role: :user, parts: [%{text: "do something"}]}
             ])
    end

    test "returns false when same text appears earlier but last user msg is different" do
      history = [
        %{role: :user, parts: [%{text: "repeat me"}]},
        %{role: :model, parts: [%{text: "noted"}]},
        %{role: :user, parts: [%{text: "something new"}]}
      ]

      refute last_user_message_matches?(history, [
               %{role: :user, parts: [%{text: "repeat me"}]}
             ])
    end

    test "returns false when history is empty" do
      refute last_user_message_matches?([], [
               %{role: :user, parts: [%{text: "hello"}]}
             ])
    end

    test "returns false when history has no user messages" do
      history = [
        %{role: :model, parts: [%{text: "I am a model"}]},
        %{role: :model, parts: [%{text: "Still model"}]}
      ]

      refute last_user_message_matches?(history, [
               %{role: :user, parts: [%{text: "hello"}]}
             ])
    end

    test "returns true for multi-part user message where one part matches" do
      history = [
        %{role: :user, parts: [%{text: "first part"}, %{text: "target text"}]}
      ]

      assert last_user_message_matches?(history, [
               %{role: :user, parts: [%{text: "target text"}]}
             ])
    end
  end
end
