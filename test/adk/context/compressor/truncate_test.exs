defmodule ADK.Context.Compressor.TruncateTest do
  use ExUnit.Case, async: true

  alias ADK.Context.Compressor.Truncate

  defp msg(role, text), do: %{role: role, parts: [%{text: text}]}

  describe "compress/3" do
    test "keeps last N messages" do
      msgs = for i <- 1..10, do: msg(:user, "msg #{i}")
      assert {:ok, result} = Truncate.compress(msgs, max_messages: 3)
      assert length(result) == 3
      assert Enum.map(result, fn m -> hd(m.parts).text end) == ["msg 8", "msg 9", "msg 10"]
    end

    test "preserves system messages by default" do
      msgs = [
        msg(:system, "You are helpful"),
        msg(:user, "msg 1"),
        msg(:user, "msg 2"),
        msg(:user, "msg 3"),
        msg(:model, "response 1"),
        msg(:user, "msg 4")
      ]

      assert {:ok, result} = Truncate.compress(msgs, max_messages: 2)
      assert length(result) == 3
      assert hd(result).role == :system
      texts = Enum.map(result, fn m -> hd(m.parts).text end)
      assert "You are helpful" in texts
    end

    test "does not preserve system when keep_system: false" do
      msgs = [
        msg(:system, "sys"),
        msg(:user, "a"),
        msg(:user, "b"),
        msg(:user, "c")
      ]

      assert {:ok, result} = Truncate.compress(msgs, max_messages: 2, keep_system: false)
      assert length(result) == 2
      refute Enum.any?(result, fn m -> m.role == :system end)
    end

    test "returns all when under max" do
      msgs = [msg(:user, "a"), msg(:user, "b")]
      assert {:ok, result} = Truncate.compress(msgs, max_messages: 10)
      assert length(result) == 2
    end

    test "uses default max_messages of 20" do
      msgs = for i <- 1..25, do: msg(:user, "msg #{i}")
      assert {:ok, result} = Truncate.compress(msgs)
      assert length(result) == 20
    end
  end
end
