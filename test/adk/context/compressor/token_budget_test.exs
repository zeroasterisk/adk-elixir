defmodule ADK.Context.Compressor.TokenBudgetTest do
  use ExUnit.Case, async: true

  alias ADK.Context.Compressor.TokenBudget

  # Helper: build a message with given role and text
  defp msg(role, text), do: %{role: role, parts: [%{text: text}]}

  # Helper: build a message where text is repeated to reach ~target_chars chars
  defp msg_of_size(role, target_chars) do
    text = String.duplicate("x", target_chars)
    msg(role, text)
  end

  # Helper: extract text from first part of a message
  defp text(%{parts: [%{text: t} | _]}), do: t

  describe "estimate_tokens/2" do
    test "returns 0 for empty list" do
      assert TokenBudget.estimate_tokens([]) == 0
    end

    test "estimates ~4 chars per token by default" do
      msgs = [msg(:user, "abcdefgh")]  # 8 chars → 2 tokens
      assert TokenBudget.estimate_tokens(msgs) == 2
    end

    test "sums across multiple messages" do
      msgs = [msg(:user, "abcdefgh"), msg(:model, "ijklmnop")]  # 8+8=16 → 4 tokens
      assert TokenBudget.estimate_tokens(msgs) == 4
    end

    test "respects custom chars_per_token" do
      msgs = [msg(:user, "abcdefgh")]  # 8 chars / 2 = 4 tokens
      assert TokenBudget.estimate_tokens(msgs, 2) == 4
    end

    test "ignores non-text parts" do
      msg = %{role: :model, parts: [%{function_call: %{name: "foo", args: %{}}}]}
      assert TokenBudget.estimate_tokens([msg]) == 0
    end

    test "handles messages without parts key" do
      msg = %{role: :user}
      assert TokenBudget.estimate_tokens([msg]) == 0
    end
  end

  describe "compress/3 — already within budget" do
    test "returns messages unchanged when under budget" do
      msgs = [msg(:user, "hi"), msg(:model, "hello")]
      # 2+5 = 7 chars → 1 token; budget 1000
      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 1000)
      assert result == msgs
    end

    test "returns empty list unchanged" do
      assert {:ok, []} = TokenBudget.compress([], token_budget: 100)
    end

    test "returns single message unchanged when it fits" do
      msgs = [msg(:user, "hello")]
      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 100)
      assert result == msgs
    end
  end

  describe "compress/3 — budget enforcement" do
    test "drops oldest messages when over budget" do
      # Each message: 40 chars → 10 tokens; budget 25 tokens fits 2
      msgs = for i <- 1..5, do: msg(:user, String.duplicate("x", 40) <> "#{i}")

      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 25, keep_recent: 1)

      # Should keep fewer than 5
      assert length(result) < 5
      # Most recent message must be present
      assert List.last(result).parts |> hd() |> Map.get(:text) |> String.ends_with?("5")
    end

    test "always keeps :keep_recent most recent messages" do
      msgs = for _i <- 1..10, do: msg(:user, String.duplicate("x", 400))

      # Budget of 1 token = nearly nothing; keep_recent: 3
      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 1, keep_recent: 3)

      # Should have at most 3 messages (the kept_recent ones)
      assert length(result) == 3
    end

    test "preserves system messages regardless of budget" do
      system = msg(:system, "You are a helpful assistant")
      user_msgs = for i <- 1..5, do: msg(:user, String.duplicate("x", 400) <> " #{i}")
      msgs = [system | user_msgs]

      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 5, keep_recent: 1)

      assert hd(result).role == :system
      assert hd(result).parts |> hd() |> Map.get(:text) == "You are a helpful assistant"
    end

    test "returns only system + recent when budget is zero or negative" do
      system = msg(:system, "sys")
      old = msg(:user, String.duplicate("o", 1000))
      recent = msg(:user, "recent")

      msgs = [system, old, recent]

      # Budget so tiny only system+recent fit (or even less)
      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 0, keep_recent: 1)

      assert system in result
      assert recent in result
      refute old in result
    end
  end

  describe "compress/3 — message ordering" do
    test "maintains oldest-to-newest order in result" do
      msgs =
        Enum.map(1..5, fn i ->
          msg(:user, "msg #{i} " <> String.duplicate("x", 4))
        end)

      # Budget: ~8 tokens per message (4+8 chars / 4), allow ~3 messages = 24 tokens
      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 30, keep_recent: 1)

      texts = Enum.map(result, &text/1)
      # Messages should be in ascending order (no duplicates, no reversal)
      sorted = Enum.sort(texts)
      assert texts == sorted or length(result) == 1
    end

    test "fills from newest-old messages first" do
      # 5 messages; budget fits only 2 non-recent (keep_recent = 1)
      # msg1 (oldest) should be dropped; msg4 (newest-old) should be kept
      msgs =
        for i <- 1..5 do
          msg(:user, "msg_#{i}_" <> String.duplicate("a", 36))
        end

      # Each message ~40 chars → 10 tokens; budget 25 → room for 2 old + 1 recent
      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 25, keep_recent: 1)

      result_texts = Enum.map(result, &text/1)

      # msg_5 (keep_recent) must be present
      assert Enum.any?(result_texts, &String.starts_with?(&1, "msg_5_"))
      # msg_4 should be present (newest-old)
      assert Enum.any?(result_texts, &String.starts_with?(&1, "msg_4_"))
      # msg_1 (oldest) should be dropped
      refute Enum.any?(result_texts, &String.starts_with?(&1, "msg_1_"))
    end
  end

  describe "compress/3 — options" do
    test "respects custom chars_per_token" do
      # With chars_per_token: 1, each char = 1 token → much smaller budget needed
      msgs = for _ <- 1..5, do: msg_of_size(:user, 100)

      # 100 tokens per message (chars_per_token: 1); budget 150 → fits 1 old + 1 recent
      assert {:ok, result} = TokenBudget.compress(msgs,
        token_budget: 250,
        chars_per_token: 1,
        keep_recent: 1
      )

      assert length(result) < 5
    end

    test "keep_system: false includes system messages in trimming" do
      msgs = [
        msg(:system, String.duplicate("s", 400)),
        msg(:user, "old"),
        msg(:user, "recent")
      ]

      # With keep_system: false, system message can be dropped
      assert {:ok, result} = TokenBudget.compress(msgs,
        token_budget: 1,
        keep_system: false,
        keep_recent: 1
      )

      # System message should not be preserved
      refute Enum.any?(result, fn m -> m.role == :system end)
    end

    test "defaults to keep_system: true" do
      system = msg(:system, "sys")
      msgs = [system, msg(:user, "old"), msg(:user, "recent")]

      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 1, keep_recent: 1)
      assert system in result
    end

    test "requires token_budget option" do
      assert_raise KeyError, fn ->
        TokenBudget.compress([msg(:user, "hi")], [])
      end
    end
  end

  describe "compress/3 — edge cases" do
    test "single message, under budget" do
      msgs = [msg(:user, "hello")]
      assert {:ok, [m]} = TokenBudget.compress(msgs, token_budget: 100)
      assert m == hd(msgs)
    end

    test "single message, over budget (keep_recent covers it)" do
      msgs = [msg(:user, String.duplicate("x", 10_000))]
      # Even over budget, keep_recent: 1 forces it to be kept
      assert {:ok, [m]} = TokenBudget.compress(msgs, token_budget: 1, keep_recent: 1)
      assert m == hd(msgs)
    end

    test "only system messages" do
      msgs = [msg(:system, "sys1"), msg(:system, "sys2")]
      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 100)
      assert result == msgs
    end

    test "multiple system messages are all preserved" do
      sys1 = msg(:system, "role 1")
      sys2 = msg(:system, "role 2")
      user = msg(:user, "hi")
      msgs = [sys1, sys2, user]

      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 1000)
      assert sys1 in result
      assert sys2 in result
    end

    test "handles messages with no text parts gracefully" do
      msgs = [
        %{role: :model, parts: [%{function_call: %{name: "foo", args: %{}}}]},
        msg(:user, "plain text")
      ]

      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 100)
      assert length(result) == 2
    end

    test "large budget keeps all messages" do
      msgs = for i <- 1..20, do: msg(:user, "message #{i}")
      assert {:ok, result} = TokenBudget.compress(msgs, token_budget: 100_000)
      assert result == msgs
    end
  end

  describe "integration with ADK.Context.Compressor.maybe_compress/2" do
    test "works via maybe_compress with threshold: 0" do
      msgs = for i <- 1..10, do: msg(:user, String.duplicate("x", 400) <> "#{i}")

      opts = [
        strategy: {TokenBudget, [token_budget: 50, keep_recent: 1]},
        threshold: 0
      ]

      result = ADK.Context.Compressor.maybe_compress(msgs, opts)

      # Should be compressed
      assert length(result) < 10
    end

    test "skips compression when below message threshold" do
      msgs = for i <- 1..3, do: msg(:user, "short #{i}")

      opts = [
        strategy: {TokenBudget, [token_budget: 5]},
        threshold: 10
      ]

      # length(msgs) = 3 < threshold 10, so no compression
      result = ADK.Context.Compressor.maybe_compress(msgs, opts)
      assert result == msgs
    end
  end
end
