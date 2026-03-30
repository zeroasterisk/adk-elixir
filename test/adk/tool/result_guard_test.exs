defmodule ADK.Tool.ResultGuardTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.ResultGuard

  describe "maybe_truncate/1 with strings" do
    test "small string passes through unchanged" do
      assert ResultGuard.maybe_truncate("hello") == "hello"
    end

    test "string at exactly max size passes through unchanged" do
      max = ResultGuard.max_bytes()
      value = String.duplicate("a", max)
      assert ResultGuard.maybe_truncate(value) == value
    end

    test "large string is truncated with marker" do
      max = ResultGuard.max_bytes()
      size = max + 10_000
      value = String.duplicate("x", size)

      result = ResultGuard.maybe_truncate(value)

      assert byte_size(result) < size

      assert result =~
               "[TRUNCATED: result was #{size} bytes, showing first #{trunc(max * 0.8)} bytes]"
    end
  end

  describe "maybe_truncate/1 with maps" do
    test "small map passes through unchanged" do
      value = %{"key" => "value"}
      assert ResultGuard.maybe_truncate(value) == value
    end

    test "large map is truncated" do
      max = ResultGuard.max_bytes()
      big_value = String.duplicate("v", max)
      value = %{"data" => big_value}

      result = ResultGuard.maybe_truncate(value)

      assert result =~ "[TRUNCATED:"
      assert byte_size(result) < byte_size(Jason.encode!(value))
    end
  end

  describe "maybe_truncate/1 with lists" do
    test "small list passes through unchanged" do
      value = [1, 2, 3]
      assert ResultGuard.maybe_truncate(value) == value
    end

    test "large list is truncated" do
      max = ResultGuard.max_bytes()
      value = Enum.map(1..max, &Integer.to_string/1)

      result = ResultGuard.maybe_truncate(value)

      assert result =~ "[TRUNCATED:"
    end
  end

  describe "maybe_truncate/1 with other types" do
    test "integer passes through unchanged" do
      assert ResultGuard.maybe_truncate(42) == 42
    end

    test "atom passes through unchanged" do
      assert ResultGuard.maybe_truncate(:ok) == :ok
    end

    test "tuple passes through unchanged" do
      assert ResultGuard.maybe_truncate({:a, :b}) == {:a, :b}
    end
  end

  describe "max_bytes option parameter" do
    test "accepts max_bytes as option" do
      value = String.duplicate("a", 200)
      result = ResultGuard.maybe_truncate(value, max_bytes: 100)

      assert result =~ "[TRUNCATED: result was 200 bytes, showing first 80 bytes]"
    end

    test "option overrides application config" do
      # Default is 50_000, but we pass 50
      value = String.duplicate("b", 100)
      result = ResultGuard.maybe_truncate(value, max_bytes: 50)

      assert result =~ "[TRUNCATED: result was 100 bytes, showing first 40 bytes]"
    end

    test "large max_bytes option lets big values through" do
      value = String.duplicate("c", 60_000)
      # Default would truncate at 50k, but we allow 100k
      assert ResultGuard.maybe_truncate(value, max_bytes: 100_000) == value
    end

    test "works with maps" do
      value = %{"data" => String.duplicate("x", 200)}
      result = ResultGuard.maybe_truncate(value, max_bytes: 50)

      assert result =~ "[TRUNCATED:"
    end
  end

  describe "application env fallback" do
    setup do
      original = Application.get_env(:adk, :max_tool_result_bytes)
      Application.put_env(:adk, :max_tool_result_bytes, 100)

      on_exit(fn ->
        if original do
          Application.put_env(:adk, :max_tool_result_bytes, original)
        else
          Application.delete_env(:adk, :max_tool_result_bytes)
        end
      end)

      :ok
    end

    test "uses configured max size when no option given" do
      assert ResultGuard.max_bytes() == 100
    end

    test "truncates at app config limit when no option given" do
      value = String.duplicate("a", 200)
      result = ResultGuard.maybe_truncate(value)

      assert result =~ "[TRUNCATED: result was 200 bytes, showing first 80 bytes]"
    end

    test "option overrides app config" do
      value = String.duplicate("a", 200)
      # App config is 100, but option says 300 — should not truncate
      assert ResultGuard.maybe_truncate(value, max_bytes: 300) == value
    end
  end
end
