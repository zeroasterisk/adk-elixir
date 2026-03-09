defmodule ADK.Context.CompressorTest do
  use ExUnit.Case, async: true

  alias ADK.Context.Compressor

  defp msg(role, text), do: %{role: role, parts: [%{text: text}]}

  describe "maybe_compress/2" do
    test "returns messages unchanged with nil opts" do
      msgs = [msg(:user, "hi")]
      assert Compressor.maybe_compress(msgs, nil) == msgs
    end

    test "returns messages unchanged with empty opts" do
      msgs = [msg(:user, "hi")]
      assert Compressor.maybe_compress(msgs, []) == msgs
    end

    test "does not compress below threshold" do
      msgs = for i <- 1..5, do: msg(:user, "msg #{i}")

      opts = [
        strategy: {Compressor.Truncate, [max_messages: 3]},
        threshold: 10
      ]

      assert Compressor.maybe_compress(msgs, opts) == msgs
    end

    test "compresses above threshold" do
      msgs = for i <- 1..10, do: msg(:user, "msg #{i}")

      opts = [
        strategy: {Compressor.Truncate, [max_messages: 3]},
        threshold: 5
      ]

      result = Compressor.maybe_compress(msgs, opts)
      assert length(result) == 3
    end
  end
end
