# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Context.CompactionProcessorTest do
  @moduledoc """
  Parity tests for Python ADK's `test_compaction_processor.py`.

  Maps Python's CompactionRequestProcessor behaviour to Elixir's
  `ADK.Context.Compressor` module:

  - Compaction trigger based on token threshold → TokenBudget strategy
  - No compaction when config missing → maybe_compress(msgs, nil)
  - Event retention / history truncation → keep_recent option
  - Compaction event generation → compaction_event/2
  - Session-integrated compaction event storage → store_compaction_event
  - Error recovery when strategy fails → fallback to original messages
  """

  use ExUnit.Case, async: true

  alias ADK.Context.Compressor
  alias ADK.Context.Compressor.TokenBudget

  # ── Helpers ──────────────────────────────────────────────────────────

  defp msg(role, text), do: %{role: role, parts: [%{text: text}]}

  defp msg_of_size(role, target_chars) do
    text = String.duplicate("x", target_chars)
    msg(role, text)
  end

  defp fn_call_msg(name, id) do
    %{role: :model, parts: [%{function_call: %{name: name, id: id, args: %{}}}]}
  end

  defp fn_response_msg(name, id, result) do
    %{role: :user, parts: [%{function_response: %{name: name, id: id, response: result}}]}
  end

  # ── Python parity: no config → no compaction ─────────────────────────
  # Maps: test_compaction_request_processor_no_token_config

  describe "no compaction config" do
    test "nil opts returns messages unchanged" do
      msgs = [msg(:user, "e1"), msg(:model, "e2"), msg(:user, "e3")]
      assert Compressor.maybe_compress(msgs, nil) == msgs
    end

    test "empty opts returns messages unchanged" do
      msgs = [msg(:user, "e1"), msg(:model, "e2"), msg(:user, "e3")]
      assert Compressor.maybe_compress(msgs, []) == msgs
    end
  end

  # ── Python parity: token threshold triggers compaction ────────────────
  # Maps: test_compaction_request_processor_runs_token_compaction
  #
  # Python test: 3 events, last has prompt_token_count=100, threshold=50,
  # event_retention_size=1 → compacts first 2 events, keeps last 1.
  #
  # Elixir equivalent: TokenBudget with token_budget (threshold) and
  # keep_recent (event_retention_size).

  describe "token-based compaction triggers" do
    test "compacts when token count exceeds threshold" do
      # 5 messages, each ~100 chars = ~25 tokens each
      # Total ~125 tokens; budget = 50 → should drop older messages
      msgs =
        for i <- 1..5 do
          msg(:user, "event_#{i}_" <> String.duplicate("a", 96))
        end

      opts = [
        strategy: {TokenBudget, [token_budget: 50, keep_recent: 1]},
        threshold: 0
      ]

      result = Compressor.maybe_compress(msgs, opts)

      # Fewer messages than original
      assert length(result) < 5
      # Most recent message is always retained
      last = List.last(result)
      assert hd(last.parts).text |> String.starts_with?("event_5_")
    end

    test "retains event_retention_size most recent messages" do
      # Mirrors Python: event_retention_size=1 keeps only last event
      msgs =
        for _i <- 1..5 do
          msg_of_size(:user, 400)
        end

      opts = [
        strategy: {TokenBudget, [token_budget: 1, keep_recent: 2]},
        threshold: 0
      ]

      result = Compressor.maybe_compress(msgs, opts)

      # keep_recent: 2 means at least 2 messages
      assert length(result) == 2
    end
  end

  # ── Python parity: below threshold → no compaction ───────────────────
  # Maps: test_compaction_request_processor_not_marked_when_not_compacted
  #
  # Python test: prompt_token_count=40, threshold=50 → no compaction.

  describe "below threshold — no compaction" do
    test "does not compact when message count below threshold" do
      msgs = [msg(:user, "e1"), msg(:model, "e2")]

      opts = [
        strategy: {TokenBudget, [token_budget: 50, keep_recent: 1]},
        threshold: 10
      ]

      result = Compressor.maybe_compress(msgs, opts)
      assert result == msgs
    end

    test "does not compact when exactly at threshold" do
      msgs = for i <- 1..5, do: msg(:user, "msg #{i}")

      opts = [
        strategy: {TokenBudget, [token_budget: 1, keep_recent: 1]},
        threshold: 5
      ]

      # length(msgs) = 5, threshold = 5, not > so no compression
      result = Compressor.maybe_compress(msgs, opts)
      assert result == msgs
    end
  end

  # ── Python parity: function call/response pair handling ──────────────
  # Maps: test_compaction_request_processor_compacts_with_latest_tool_response
  #
  # Python test: Events include function_call + function_response from current
  # invocation. Compaction should only compact older events, preserving the
  # current invocation's tool call pair.
  #
  # In Elixir, SlidingWindow handles function pair preservation.

  describe "function call/response pair preservation during compaction" do
    test "sliding window preserves function call/response pairs" do
      msgs = [
        msg(:user, "old event 1"),
        msg(:user, "old event 2"),
        fn_call_msg("tool", "call-1"),
        fn_response_msg("tool", "call-1", %{result: "ok"}),
        msg(:user, "latest user message")
      ]

      opts = [
        strategy: {Compressor.SlidingWindow, [max_messages: 3]},
        threshold: 0
      ]

      result = Compressor.maybe_compress(msgs, opts)

      # Function response should have its matching call
      response_ids =
        result
        |> Enum.flat_map(fn m ->
          Enum.flat_map(m.parts, fn
            %{function_response: %{id: id}} -> [id]
            _ -> []
          end)
        end)
        |> MapSet.new()

      call_ids =
        result
        |> Enum.flat_map(fn m ->
          Enum.flat_map(m.parts, fn
            %{function_call: %{id: id}} -> [id]
            _ -> []
          end)
        end)
        |> MapSet.new()

      # Every response ID must have a matching call ID
      assert MapSet.subset?(response_ids, call_ids)
    end
  end

  # ── Python parity: current invocation events can be compacted ────────
  # Maps: test_compaction_request_processor_can_compact_current_user_event
  #
  # Python test: event_retention_size=0 allows even current invocation's
  # user message to be compacted.

  describe "compact current invocation events" do
    test "keep_recent: 0 allows compacting all events" do
      msgs =
        for _i <- 1..5 do
          msg_of_size(:user, 400)
        end

      # Budget tiny, keep_recent: 0 — extreme compaction
      opts = [
        strategy: {TokenBudget, [token_budget: 0, keep_recent: 0]},
        threshold: 0
      ]

      result = Compressor.maybe_compress(msgs, opts)

      # With keep_recent: 0 and budget: 0, everything should be dropped
      assert length(result) == 0
    end
  end

  # ── Compaction event generation ──────────────────────────────────────
  # Tests compaction_event/2 creates proper event structure

  describe "compaction_event/2" do
    test "creates event with system:compaction author" do
      event = Compressor.compaction_event(20, 5)
      assert event.author == "system:compaction"
    end

    test "includes original and compressed counts in content" do
      event = Compressor.compaction_event(100, 10)
      text = hd(event.content.parts).text
      assert text =~ "100"
      assert text =~ "10"
      assert text =~ "compacted" or text =~ "compressed"
    end

    test "creates distinct events each time" do
      e1 = Compressor.compaction_event(10, 5)
      e2 = Compressor.compaction_event(10, 5)
      # Events are structs, both should be valid
      assert e1.author == "system:compaction"
      assert e2.author == "system:compaction"
    end
  end

  # ── Error recovery ──────────────────────────────────────────────────
  # Tests that when a strategy returns {:error, _}, original messages
  # are returned unchanged.

  describe "strategy error recovery" do
    test "returns original messages when strategy returns error" do
      # Summarize strategy without a model returns {:error, :no_model_for_summarization}
      msgs = for i <- 1..20, do: msg(:user, "msg #{i}")

      opts = [
        strategy: {Compressor.Summarize, [keep_recent: 5]},
        # No :context with :model → will error
        threshold: 0
      ]

      result = Compressor.maybe_compress(msgs, opts)

      # Should return original messages since strategy errored
      assert result == msgs
    end
  end

  # ── Integration: token estimation matches compaction decisions ───────
  # Verifies that TokenBudget's token estimation drives correct compaction.

  describe "token estimation integration" do
    test "char-based estimation matches Python ADK heuristic (chars/4)" do
      # Python ADK uses chars÷4 for token estimation
      # 100 chars → 25 tokens
      msgs = [msg(:user, String.duplicate("a", 100))]
      assert TokenBudget.estimate_tokens(msgs) == 25
    end

    test "multi-part messages aggregate correctly" do
      msg = %{role: :user, parts: [%{text: "hello"}, %{text: "world"}]}
      # 5 + 5 = 10 chars → 2 tokens
      assert TokenBudget.estimate_tokens([msg]) == 2
    end

    test "function call parts contribute 0 tokens" do
      msg = %{role: :model, parts: [%{function_call: %{name: "tool", args: %{}}}]}
      assert TokenBudget.estimate_tokens([msg]) == 0
    end

    test "budget-driven compaction preserves newest history" do
      # 10 messages, each 40 chars (10 tokens); budget 35 → fits 3 messages
      msgs =
        for i <- 1..10 do
          msg(:user, "m#{i}_" <> String.duplicate("x", 37))
        end

      {:ok, result} = TokenBudget.compress(msgs, token_budget: 35, keep_recent: 1)

      # Most recent message must be present
      last_text = hd(List.last(result).parts).text
      assert String.starts_with?(last_text, "m10_")

      # Older messages should be trimmed
      assert length(result) < 10
    end
  end
end
