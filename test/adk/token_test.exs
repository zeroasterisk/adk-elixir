defmodule ADK.TokenTest do
  use ExUnit.Case, async: true

  alias ADK.Token

  describe "estimate_count/1 with strings" do
    test "estimates tokens for a string" do
      # "hello world" = 11 chars, 11 / 4 = 2
      assert Token.estimate_count("hello world") == 2
    end

    test "empty string returns 0" do
      assert Token.estimate_count("") == 0
    end

    test "short string rounds down" do
      # "hi" = 2 chars, 2 / 4 = 0
      assert Token.estimate_count("hi") == 0
    end

    test "longer string" do
      # 100 chars / 4 = 25
      text = String.duplicate("a", 100)
      assert Token.estimate_count(text) == 25
    end
  end

  describe "estimate_count/1 with message maps" do
    test "single message with text parts" do
      msg = %{role: :user, parts: [%{text: "hello world"}]}
      assert Token.estimate_count(msg) == 2
    end

    test "message with multiple text parts" do
      msg = %{role: :user, parts: [%{text: "hello"}, %{text: " world"}]}
      # 5 + 6 = 11 chars, 11 / 4 = 2
      assert Token.estimate_count(msg) == 2
    end

    test "message with non-text parts" do
      msg = %{role: :user, parts: [%{image: "data:image/png;base64,abc"}]}
      assert Token.estimate_count(msg) == 0
    end

    test "message with mixed parts" do
      msg = %{role: :user, parts: [%{text: "hello"}, %{image: "data:..."}]}
      # 5 / 4 = 1
      assert Token.estimate_count(msg) == 1
    end

    test "message with nil parts field" do
      msg = %{role: :user}
      assert Token.estimate_count(msg) == 0
    end

    test "empty parts list" do
      msg = %{role: :user, parts: []}
      assert Token.estimate_count(msg) == 0
    end
  end

  describe "estimate_count/1 with lists of messages" do
    test "multiple messages" do
      msgs = [
        %{role: :user, parts: [%{text: "hello"}]},
        %{role: :model, parts: [%{text: "hi there"}]}
      ]

      # 5/4 + 8/4 = 1 + 2 = 3
      assert Token.estimate_count(msgs) == 3
    end

    test "empty list returns 0" do
      assert Token.estimate_count([]) == 0
    end
  end

  describe "estimate_count/2 with custom chars_per_token" do
    test "custom chars_per_token for string" do
      # "hello" = 5 chars, 5 / 2 = 2
      assert Token.estimate_count("hello", chars_per_token: 2) == 2
    end

    test "custom chars_per_token for messages" do
      msg = %{role: :user, parts: [%{text: "hello world"}]}
      # 11 / 3 = 3
      assert Token.estimate_count(msg, chars_per_token: 3) == 3
    end

    test "chars_per_token of 1 returns char count" do
      assert Token.estimate_count("hello", chars_per_token: 1) == 5
    end
  end
end
