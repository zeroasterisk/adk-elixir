defmodule Claw.EvalTest do
  @moduledoc """
  Evaluation tests for the Claw agent.

  Demonstrates ADK.Eval — running the agent through realistic scenarios
  and scoring responses using pluggable scorers.

  Uses ADK.LLM.Mock (the default test backend) for deterministic, API-free evals.
  Mock responses are set via `ADK.LLM.Mock.set_responses/1` before each test.
  """

  use ExUnit.Case, async: false

  alias ADK.Eval
  alias ADK.Eval.{Case, Scorer}

  # ---------------------------------------------------------------------------
  # Setup — ensure Mock LLM is active
  # ---------------------------------------------------------------------------

  setup do
    original_backend = Application.get_env(:adk, :llm_backend)
    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:adk, :llm_backend, original_backend)
      else
        Application.delete_env(:adk, :llm_backend)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helper — test runner with basic tools
  # ---------------------------------------------------------------------------

  defp build_eval_runner do
    agent = ADK.Agent.LlmAgent.new(
      name: "claw_eval",
      model: "gemini-2.0-flash-lite",
      description: "Claw eval agent",
      instruction: "You are Claw, a helpful AI assistant.",
      tools: Claw.Tools.basic_tools()
    )

    ADK.Runner.new(app_name: "claw_eval", agent: agent)
  end

  # ---------------------------------------------------------------------------
  # Eval Cases
  # ---------------------------------------------------------------------------

  @eval_cases [
    Case.new(
      name: "greeting_response",
      input: "Hello! What can you do?",
      scorers: [
        {Scorer.Contains, text: "help", case_sensitive: false},
        {Scorer.ResponseLength, min: 10, max: 500}
      ],
      metadata: %{category: "basic", description: "Agent should mention it can help"}
    ),

    Case.new(
      name: "response_not_empty",
      input: "What time is it?",
      scorers: [
        {Scorer.ResponseLength, min: 5, max: 1000}
      ],
      metadata: %{category: "basic", description: "Agent must respond to any query"}
    ),

    Case.new(
      name: "helpful_tone",
      input: "Can you help me?",
      scorers: [
        {Scorer.Contains, text: "help", case_sensitive: false},
        {Scorer.ResponseLength, min: 5, max: 500}
      ],
      metadata: %{category: "quality", description: "Agent should confirm it can help"}
    )
  ]

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "ADK.Eval framework" do
    test "eval cases have valid structure" do
      Enum.each(@eval_cases, fn eval_case ->
        assert %Case{} = eval_case
        assert is_binary(eval_case.name)
        assert is_binary(eval_case.input)
        assert length(eval_case.scorers) > 0
      end)
    end

    test "eval scorers are properly configured" do
      for eval_case <- @eval_cases do
        for {scorer_mod, opts} <- eval_case.scorers do
          assert is_atom(scorer_mod), "Scorer module should be an atom in #{eval_case.name}"
          assert is_list(opts), "Scorer opts should be a keyword list in #{eval_case.name}"
        end
      end
    end

    @tag :eval
    test "run eval suite against mock runner" do
      # Seed the Mock LLM with helpful responses for each case
      ADK.LLM.Mock.set_responses([
        "I can help you with many things including tools and information!",
        "The current time is available via the datetime tool. Let me help!",
        "Of course, I can help you! I have access to datetime, file reading, and shell tools."
      ])

      runner = build_eval_runner()
      report = Eval.run(runner, @eval_cases)

      assert %ADK.Eval.Report{} = report
      assert report.total == length(@eval_cases)
      assert report.total == report.passed + report.failed
      assert is_float(report.average_score)
      assert report.duration_ms >= 0

      for result <- report.results do
        assert is_binary(result.case_name)
        assert is_float(result.aggregate_score)
        assert result.aggregate_score >= 0.0
        assert result.aggregate_score <= 1.0
        assert is_boolean(result.pass)
      end
    end

    @tag :eval
    test "eval report can be formatted" do
      ADK.LLM.Mock.set_responses([
        "I can help with that!",
        "Sure, I can help!",
        "Absolutely, let me help you!"
      ])

      runner = build_eval_runner()
      report = Eval.run(runner, @eval_cases)
      formatted = ADK.Eval.Report.format(report)

      assert is_binary(formatted)
      assert formatted =~ "Eval Report"
    end
  end

  describe "Claw scorer tests" do
    test "Contains scorer matches text in response" do
      events = [
        %ADK.Event{
          id: "e1",
          author: "claw_eval",
          partial: false,
          content: %{parts: [%{text: "I can help with tools and information."}]}
        }
      ]

      result = Scorer.Contains.score(events, text: "help", case_sensitive: false)
      assert result.pass == true
      assert result.score == 1.0
    end

    test "Contains scorer fails when text not present" do
      events = [
        %ADK.Event{
          id: "e1",
          author: "claw_eval",
          partial: false,
          content: %{parts: [%{text: "The weather is sunny today."}]}
        }
      ]

      result = Scorer.Contains.score(events, text: "programming", case_sensitive: false)
      assert result.pass == false
      assert result.score == 0.0
    end

    test "ResponseLength scorer passes for adequate length" do
      events = [
        %ADK.Event{
          id: "e1",
          author: "claw_eval",
          partial: false,
          content: %{parts: [%{text: "This is a reasonable response from the agent."}]}
        }
      ]

      result = Scorer.ResponseLength.score(events, min: 10, max: 500)
      assert result.pass == true
    end

    test "ResponseLength scorer fails for too short response" do
      events = [
        %ADK.Event{
          id: "e1",
          author: "claw_eval",
          partial: false,
          content: %{parts: [%{text: "Hi"}]}
        }
      ]

      result = Scorer.ResponseLength.score(events, min: 10, max: 500)
      assert result.pass == false
    end
  end
end
