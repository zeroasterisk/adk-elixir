defmodule ADK.HarnessTest do
  use ExUnit.Case, async: true

  alias ADK.Harness
  alias ADK.Harness.Feedback

  defp make_agent(opts \\ []) do
    response = opts[:response] || "Hello from agent"

    ADK.Agent.Custom.new(
      name: opts[:name] || "test_agent",
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(author: "test_agent", content: response)]
      end
    )
  end

  describe "L1 — simple run" do
    test "runs agent and returns result" do
      agent = make_agent()
      {:ok, result} = Harness.run(agent, "do something")

      assert result.status == :ok
      assert result.steps >= 1
      assert result.duration_ms >= 0
      assert is_map(result.tokens)
    end

    test "returns events" do
      agent = make_agent()
      {:ok, result} = Harness.run(agent, "do something")
      assert is_list(result.events)
    end
  end

  describe "L2 — budget" do
    test "respects max_steps budget" do
      agent = make_agent()

      {:ok, result} =
        Harness.run(agent, "do something", budget: %{max_steps: 1})

      assert result.steps >= 1
    end
  end

  describe "L2 — guardrails" do
    test "blocks input matching guardrail" do
      agent = make_agent()
      guardrail = ADK.Guardrail.ContentFilter.new(blocked_words: ["forbidden"])

      {:ok, result} =
        Harness.run(agent, "this is forbidden content", guardrails: [guardrail])

      assert result.status == :guardrail_blocked
    end

    test "allows clean input" do
      agent = make_agent()
      guardrail = ADK.Guardrail.ContentFilter.new(blocked_words: ["forbidden"])

      {:ok, result} =
        Harness.run(agent, "this is fine", guardrails: [guardrail])

      assert result.status == :ok
    end
  end

  describe "L2 — hooks" do
    test "calls before_step hook" do
      test_pid = self()
      agent = make_agent()

      {:ok, _result} =
        Harness.run(agent, "do something",
          hooks: %{
            before_step: fn step, state ->
              send(test_pid, {:before_step, step})
              state
            end
          }
        )

      assert_receive {:before_step, 1}
    end

    test "calls after_step hook" do
      test_pid = self()
      agent = make_agent()

      {:ok, _result} =
        Harness.run(agent, "do something",
          hooks: %{
            after_step: fn step, _result, state ->
              send(test_pid, {:after_step, step})
              state
            end
          }
        )

      assert_receive {:after_step, 1}
    end
  end

  describe "L3 — feedback" do
    test "accepts output that passes verification" do
      agent = make_agent(response: "good output")

      feedback = %Feedback{
        verifier: fn _output -> :ok end,
        max_retries: 3
      }

      {:ok, result} = Harness.run(agent, "do something", feedback: feedback)
      assert result.status == :ok
    end

    test "rejects after max retries exhausted" do
      agent = make_agent(response: "bad")

      feedback = %Feedback{
        verifier: fn _output -> {:reject, "always bad"} end,
        max_retries: 1
      }

      {:ok, result} = Harness.run(agent, "do something", feedback: feedback)
      assert result.status == :feedback_rejected
    end
  end
end
