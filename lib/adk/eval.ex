defmodule ADK.Eval do
  @moduledoc """
  Evaluation framework for testing agent quality.

  Run an agent against a suite of test cases and score the responses
  using pluggable scorers.

  ## Quick start

      alias ADK.Eval
      alias ADK.Eval.{Case, Scorer}

      cases = [
        Case.new(
          name: "greeting",
          input: "Say hello",
          scorers: [
            {Scorer.Contains, text: "hello", case_sensitive: false},
            {Scorer.ResponseLength, min: 1, max: 500}
          ]
        )
      ]

      runner = ADK.Runner.new(app_name: "test", agent: my_agent)
      report = Eval.run(runner, cases)
      IO.puts(Eval.Report.format(report))

  ## Options for `run/3`

    * `:threshold` - minimum aggregate score to pass a case (default: 1.0, meaning all scorers must pass)
    * `:user_id` - user ID for the session (default: "eval_user")
  """

  alias ADK.Eval.{Case, Result, Report}

  @doc """
  Run an agent against a list of eval cases, returning a report.
  """
  @spec run(ADK.Runner.t(), [Case.t()], keyword()) :: Report.t()
  def run(%ADK.Runner{} = runner, cases, opts \\ []) when is_list(cases) do
    threshold = Keyword.get(opts, :threshold, 1.0)
    user_id = Keyword.get(opts, :user_id, "eval_user")

    start = System.monotonic_time(:millisecond)

    results =
      Enum.map(cases, fn %Case{} = eval_case ->
        run_case(runner, eval_case, user_id, threshold)
      end)

    duration = System.monotonic_time(:millisecond) - start
    passed = Enum.count(results, & &1.pass)
    total = length(results)

    avg =
      if total > 0 do
        results |> Enum.map(& &1.aggregate_score) |> Enum.sum() |> Kernel./(total)
      else
        0.0
      end

    %Report{
      total: total,
      passed: passed,
      failed: total - passed,
      results: results,
      average_score: avg,
      duration_ms: duration
    }
  end

  defp run_case(runner, %Case{} = eval_case, user_id, threshold) do
    session_id = "eval_#{eval_case.name}_#{System.unique_integer([:positive])}"
    start = System.monotonic_time(:millisecond)

    events =
      try do
        ADK.Runner.run(runner, user_id, session_id, eval_case.input)
      rescue
        e -> [ADK.Event.new(%{author: "system", content: nil, error: Exception.message(e)})]
      end

    duration = System.monotonic_time(:millisecond) - start

    scores =
      Enum.map(eval_case.scorers, fn {scorer_mod, scorer_opts} ->
        result = scorer_mod.score(events, scorer_opts)
        Map.put(result, :scorer, scorer_mod)
      end)

    agg =
      if scores == [] do
        1.0
      else
        scores |> Enum.map(& &1.score) |> Enum.sum() |> Kernel./(length(scores))
      end

    %Result{
      case_name: eval_case.name,
      pass: agg >= threshold,
      scores: scores,
      aggregate_score: agg,
      events: events,
      duration_ms: duration
    }
  end
end
