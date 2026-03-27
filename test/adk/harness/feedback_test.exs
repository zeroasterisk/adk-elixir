defmodule ADK.Harness.FeedbackTest do
  use ExUnit.Case, async: true

  alias ADK.Harness.Feedback

  describe "verify/2" do
    test "returns :ok when verifier accepts" do
      fb = %Feedback{verifier: fn _ -> :ok end}
      assert Feedback.verify(fb, "good") == :ok
    end

    test "returns {:reject, reason} when verifier rejects" do
      fb = %Feedback{verifier: fn _ -> {:reject, "bad"} end}
      assert Feedback.verify(fb, "output") == {:reject, "bad"}
    end
  end

  describe "retry_message/3" do
    test "uses custom on_reject callback" do
      fb = %Feedback{
        verifier: fn _ -> :ok end,
        on_reject: fn reason, attempt -> "Custom: #{reason} (#{attempt})" end
      }

      assert Feedback.retry_message(fb, "bad output", 2) == "Custom: bad output (2)"
    end

    test "uses default message when no on_reject" do
      fb = %Feedback{verifier: fn _ -> :ok end}
      msg = Feedback.retry_message(fb, "too short", 1)
      assert msg =~ "too short"
      assert msg =~ "attempt 1"
    end
  end

  describe "retries_remaining?/2" do
    test "returns true when attempts left" do
      fb = %Feedback{verifier: fn _ -> :ok end, max_retries: 3}
      assert Feedback.retries_remaining?(fb, 1)
      assert Feedback.retries_remaining?(fb, 2)
    end

    test "returns false when max reached" do
      fb = %Feedback{verifier: fn _ -> :ok end, max_retries: 3}
      refute Feedback.retries_remaining?(fb, 3)
      refute Feedback.retries_remaining?(fb, 4)
    end
  end
end
