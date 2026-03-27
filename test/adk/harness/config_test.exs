defmodule ADK.Harness.ConfigTest do
  use ExUnit.Case, async: true

  alias ADK.Harness.Config

  describe "from_opts/1" do
    test "provides sane defaults" do
      config = Config.from_opts([])
      assert config.budget.max_steps == 10
      assert config.budget.max_duration_ms == :timer.minutes(5)
      assert config.guardrails == []
      assert config.hooks == %{}
      assert config.feedback == nil
    end

    test "merges user budget with defaults" do
      config = Config.from_opts(budget: %{max_steps: 20, max_tokens: 5000})
      assert config.budget.max_steps == 20
      assert config.budget.max_tokens == 5000
      assert config.budget.max_duration_ms == :timer.minutes(5)
    end

    test "passes through guardrails" do
      guardrail = ADK.Guardrail.ContentFilter.new(blocked_words: ["bad"])
      config = Config.from_opts(guardrails: [guardrail])
      assert length(config.guardrails) == 1
    end

    test "passes through hooks" do
      hooks = %{before_step: fn _, s -> s end}
      config = Config.from_opts(hooks: hooks)
      assert is_function(config.hooks[:before_step])
    end

    test "passes through feedback" do
      fb = %ADK.Harness.Feedback{verifier: fn _ -> :ok end}
      config = Config.from_opts(feedback: fb)
      assert config.feedback == fb
    end
  end

  describe "default_budget/0" do
    test "returns expected defaults" do
      defaults = Config.default_budget()
      assert defaults.max_steps == 10
      assert defaults.max_tokens == nil
    end
  end
end
