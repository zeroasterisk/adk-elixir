defmodule ADK.ErrorTest do
  @moduledoc """
  Tests for ADK.Error structured error types.
  """
  use ExUnit.Case, async: true
  doctest ADK.Error

  alias ADK.Error

  describe "new/3" do
    test "creates an error with all fields" do
      error =
        Error.new(:llm_timeout, "Model timed out",
          category: :llm,
          recovery: "Retry with a longer timeout",
          details: %{provider: "openai", model: "gpt-4"},
          cause: :timeout
        )

      assert error.code == :llm_timeout
      assert error.message == "Model timed out"
      assert error.category == :llm
      assert error.recovery == "Retry with a longer timeout"
      assert error.details == %{provider: "openai", model: "gpt-4"}
      assert error.cause == :timeout
    end

    test "defaults category, recovery, details, and cause" do
      error = Error.new(:unknown_thing, "Something happened")

      assert error.category == :internal
      assert error.recovery == nil
      assert error.details == %{}
      assert error.cause == nil
    end

    test "auto-infers category from code prefix" do
      assert Error.new(:llm_timeout, "timeout").category == :llm
      assert Error.new(:tool_not_found, "missing").category == :tool
      assert Error.new(:auth_failed, "bad creds").category == :auth
      assert Error.new(:config_invalid, "bad config").category == :config
      assert Error.new(:session_not_found, "gone").category == :session
      assert Error.new(:workflow_failed, "broke").category == :workflow
      assert Error.new(:network_error, "down").category == :network
      assert Error.new(:internal_bug, "oops").category == :internal
    end

    test "explicit category overrides inferred category" do
      error = Error.new(:llm_timeout, "timeout", category: :network)
      assert error.category == :network
    end

    test "falls back to :internal for unrecognized code prefix" do
      error = Error.new(:banana_split, "dessert error")
      assert error.category == :internal
    end
  end

  describe "wrap/4" do
    test "wraps an existing error as cause" do
      original = %RuntimeError{message: "connection reset"}
      wrapped = Error.wrap(:llm_timeout, "LLM call failed", original)

      assert wrapped.code == :llm_timeout
      assert wrapped.message == "LLM call failed"
      assert wrapped.cause == original
    end

    test "wraps an ADK.Error as cause" do
      inner = Error.new(:auth_failed, "Token expired")
      outer = Error.wrap(:llm_timeout, "LLM call failed", inner, category: :llm)

      assert outer.cause == inner
      assert outer.cause.code == :auth_failed
    end

    test "preserves opts alongside cause" do
      original = :some_reason
      wrapped = Error.wrap(:tool_not_found, "Missing tool", original, recovery: "Check config")

      assert wrapped.cause == :some_reason
      assert wrapped.recovery == "Check config"
    end
  end

  describe "convenience constructors" do
    test "llm_error/2 sets category to :llm" do
      error = Error.llm_error("Model unavailable", details: %{model: "claude"})

      assert error.code == :llm_error
      assert error.category == :llm
      assert error.message == "Model unavailable"
      assert error.details == %{model: "claude"}
    end

    test "tool_error/2 sets category to :tool" do
      error = Error.tool_error("Tool crashed", code: :tool_exec_failed)

      assert error.code == :tool_exec_failed
      assert error.category == :tool
    end

    test "config_error/2 sets category to :config" do
      error = Error.config_error("Missing API key")

      assert error.code == :config_error
      assert error.category == :config
    end

    test "auth_error/2 sets category to :auth" do
      error = Error.auth_error("Token expired", recovery: "Refresh the token")

      assert error.code == :auth_error
      assert error.category == :auth
      assert error.recovery == "Refresh the token"
    end
  end

  describe "retryable?/1" do
    test "llm_timeout is retryable" do
      assert Error.retryable?(Error.new(:llm_timeout, "timeout"))
    end

    test "rate_limited is retryable" do
      assert Error.retryable?(Error.new(:rate_limited, "slow down"))
    end

    test "network category errors are retryable" do
      assert Error.retryable?(Error.new(:network_error, "connection reset"))
      assert Error.retryable?(Error.new(:anything, "down", category: :network))
    end

    test "non-retryable errors" do
      refute Error.retryable?(Error.new(:tool_not_found, "missing"))
      refute Error.retryable?(Error.new(:auth_failed, "bad creds"))
      refute Error.retryable?(Error.new(:config_invalid, "bad config"))
    end
  end

  describe "to_map/1" do
    test "serializes basic error to map" do
      error = Error.new(:llm_timeout, "timeout", category: :llm, details: %{ms: 30_000})
      map = Error.to_map(error)

      assert map.code == :llm_timeout
      assert map.message == "timeout"
      assert map.category == :llm
      assert map.details == %{ms: 30_000}
      refute Map.has_key?(map, :recovery)
      refute Map.has_key?(map, :cause)
    end

    test "includes recovery when present" do
      error = Error.new(:llm_timeout, "timeout", recovery: "retry")
      map = Error.to_map(error)

      assert map.recovery == "retry"
    end

    test "formats ADK.Error cause as nested map" do
      inner = Error.new(:auth_failed, "expired")
      outer = Error.wrap(:llm_timeout, "failed", inner)
      map = Error.to_map(outer)

      assert is_map(map.cause)
      assert map.cause.code == :auth_failed
    end

    test "formats standard exception cause as string" do
      original = %RuntimeError{message: "boom"}
      error = Error.wrap(:tool_not_found, "failed", original)
      map = Error.to_map(error)

      assert map.cause == "boom"
    end

    test "formats arbitrary cause with inspect" do
      error = Error.wrap(:tool_not_found, "failed", {:error, :econnrefused})
      map = Error.to_map(error)

      assert map.cause == "{:error, :econnrefused}"
    end
  end

  describe "Exception.message/1" do
    test "formats as [category:code] message" do
      error = Error.new(:llm_timeout, "Model timed out", category: :llm)
      assert Exception.message(error) == "[llm:llm_timeout] Model timed out"
    end

    test "works with raise/rescue" do
      assert_raise Error, "[tool:tool_not_found] Calculator missing", fn ->
        raise Error.new(:tool_not_found, "Calculator missing")
      end
    end
  end

  describe "defexception integration" do
    test "is an exception" do
      error = Error.new(:llm_timeout, "timeout")
      assert Exception.exception?(error)
    end

    test "can be raised and rescued" do
      result =
        try do
          raise Error.new(:config_invalid, "bad config")
        rescue
          e in Error ->
            {:caught, e.code}
        end

      assert result == {:caught, :config_invalid}
    end
  end
end
