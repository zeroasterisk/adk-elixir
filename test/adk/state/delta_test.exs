defmodule ADK.State.DeltaTest do
  @moduledoc """
  Tests demonstrating how session state changes work in ADK.

  When tools update session state during an agent run, ADK captures the
  difference as a Delta — tracking what was added, changed, and removed.
  These tests show the developer workflow for tracking state changes
  between turns, applying them, and understanding what happened.
  """
  use ExUnit.Case, async: true
  doctest ADK.State.Delta

  alias ADK.State.Delta

  describe "tracking what a tool changed in session state" do
    test "when a tool adds new state, the delta captures the additions" do
      before_tool = %{}
      after_tool = %{user_name: "Alan", preferences: %{theme: "dark"}}

      delta = Delta.diff(before_tool, after_tool)

      assert delta.added == %{user_name: "Alan", preferences: %{theme: "dark"}}
      assert delta.changed == %{}
      assert delta.removed == []
    end

    test "when a tool updates existing state, the delta captures the changes" do
      before_tool = %{mood: "neutral", request_count: 3}
      after_tool = %{mood: "happy", request_count: 4}

      delta = Delta.diff(before_tool, after_tool)

      assert delta.changed == %{mood: "happy", request_count: 4}
      assert delta.added == %{}
      assert delta.removed == []
    end

    test "when a tool clears state, the delta captures the removals" do
      before_tool = %{temp_token: "abc123", session_data: %{step: 2}}
      after_tool = %{session_data: %{step: 2}}

      delta = Delta.diff(before_tool, after_tool)

      assert :temp_token in delta.removed
      assert delta.added == %{}
    end
  end

  describe "applying state changes between turns" do
    test "apply a tool's state delta to get the updated session state" do
      session_state = %{user_name: "Alan", request_count: 5}

      # The tool added a new key, updated a counter, and cleared nothing
      tool_delta = %{
        added: %{last_query: "weather in Louisville"},
        changed: %{request_count: 6},
        removed: []
      }

      updated = Delta.apply_delta(session_state, tool_delta)

      assert updated == %{
               user_name: "Alan",
               request_count: 6,
               last_query: "weather in Louisville"
             }
    end

    test "apply a delta that removes temporary state after use" do
      session_state = %{user_name: "Alan", pending_confirmation: true, draft_email: "..."}

      confirmation_delta = %{
        added: %{emails_sent: 1},
        changed: %{},
        removed: [:pending_confirmation, :draft_email]
      }

      updated = Delta.apply_delta(session_state, confirmation_delta)

      assert updated == %{user_name: "Alan", emails_sent: 1}
      refute Map.has_key?(updated, :pending_confirmation)
      refute Map.has_key?(updated, :draft_email)
    end
  end

  describe "inspecting what changed between turns" do
    test "diff and apply are inverses — applying the diff reproduces the new state" do
      old_state = %{score: 10, level: 1}
      new_state = %{score: 25, level: 2, badge: "explorer"}

      delta = Delta.diff(old_state, new_state)
      reconstructed = Delta.apply_delta(old_state, delta)

      assert reconstructed == new_state
    end

    test "no changes produce an empty delta" do
      state = %{user_name: "Alan", theme: "dark"}
      delta = Delta.diff(state, state)

      assert delta == %{added: %{}, changed: %{}, removed: []}
    end
  end
end
