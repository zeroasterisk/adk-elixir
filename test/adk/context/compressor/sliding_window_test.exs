defmodule ADK.Context.Compressor.SlidingWindowTest do
  use ExUnit.Case, async: true

  alias ADK.Context.Compressor.SlidingWindow

  defp msg(role, text), do: %{role: role, parts: [%{text: text}]}

  defp fn_call_msg(name, id) do
    %{role: :model, parts: [%{function_call: %{name: name, id: id, args: %{}}}]}
  end

  defp fn_response_msg(name, id, result) do
    %{role: :user, parts: [%{function_response: %{name: name, id: id, response: result}}]}
  end

  describe "compress/3 with max_messages" do
    test "keeps last N messages" do
      msgs = for i <- 1..10, do: msg(:user, "msg #{i}")
      assert {:ok, result} = SlidingWindow.compress(msgs, max_messages: 3)
      assert length(result) == 3
      texts = Enum.map(result, fn m -> hd(m.parts).text end)
      assert texts == ["msg 8", "msg 9", "msg 10"]
    end

    test "preserves system messages" do
      msgs = [msg(:system, "sys")] ++ for i <- 1..10, do: msg(:user, "msg #{i}")
      assert {:ok, result} = SlidingWindow.compress(msgs, max_messages: 3)
      assert length(result) == 4
      assert hd(result).role == :system
    end

    test "returns all when under max" do
      msgs = [msg(:user, "a"), msg(:user, "b")]
      assert {:ok, result} = SlidingWindow.compress(msgs, max_messages: 10)
      assert length(result) == 2
    end

    test "expands window to keep function call/response pairs" do
      msgs = [
        msg(:user, "hello"),
        fn_call_msg("search", "call-1"),
        fn_response_msg("search", "call-1", "result"),
        msg(:model, "here's what I found"),
        msg(:user, "thanks")
      ]

      # max_messages: 3 would split at index 2, orphaning function_response from call
      assert {:ok, result} = SlidingWindow.compress(msgs, max_messages: 3)
      # Should expand to include the function call
      assert length(result) >= 3

      # Verify no orphaned responses
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

      assert MapSet.subset?(response_ids, call_ids)
    end
  end

  describe "compress/3 with invocations" do
    test "keeps last N invocations" do
      msgs = [
        msg(:user, "first question"),
        msg(:model, "first answer"),
        msg(:user, "second question"),
        msg(:model, "second answer"),
        msg(:user, "third question"),
        msg(:model, "third answer")
      ]

      assert {:ok, result} = SlidingWindow.compress(msgs, invocations: 2)
      assert length(result) == 4
      texts = Enum.map(result, fn m -> hd(m.parts).text end)
      assert texts == ["second question", "second answer", "third question", "third answer"]
    end

    test "keeps all when fewer invocations than limit" do
      msgs = [
        msg(:user, "q1"),
        msg(:model, "a1")
      ]

      assert {:ok, result} = SlidingWindow.compress(msgs, invocations: 5)
      assert result == msgs
    end

    test "handles multi-turn invocations with tool calls" do
      msgs = [
        msg(:user, "old question"),
        msg(:model, "old answer"),
        msg(:user, "search for X"),
        fn_call_msg("search", "c1"),
        fn_response_msg("search", "c1", "found X"),
        msg(:model, "here's X"),
        msg(:user, "latest question"),
        msg(:model, "latest answer")
      ]

      assert {:ok, result} = SlidingWindow.compress(msgs, invocations: 1)
      _texts = Enum.map(result, fn m -> hd(m.parts) end)
      # Should keep last invocation: "latest question" + "latest answer"
      assert length(result) == 2
    end

    test "does not count function responses as invocation starts" do
      msgs = [
        msg(:user, "question"),
        fn_call_msg("tool", "c1"),
        fn_response_msg("tool", "c1", "result"),
        msg(:model, "answer"),
        msg(:user, "follow up"),
        msg(:model, "follow up answer")
      ]

      assert {:ok, result} = SlidingWindow.compress(msgs, invocations: 1)
      # Last invocation is "follow up" + "follow up answer"
      assert length(result) == 2
    end
  end
end
