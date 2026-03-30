defmodule ADK.Eval.Report do
  @moduledoc "Summary report of an evaluation run."

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          results: [ADK.Eval.Result.t()],
          average_score: float(),
          duration_ms: non_neg_integer()
        }

  defstruct [:total, :passed, :failed, :average_score, :duration_ms, results: []]

  @doc "Format report as a human-readable string."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = report) do
    header =
      "Eval Report: #{report.passed}/#{report.total} passed (avg score: #{Float.round(report.average_score, 3)})\n"

    details =
      report.results
      |> Enum.map(fn r ->
        status = if r.pass, do: "✅", else: "❌"

        scores =
          Enum.map_join(r.scores, ", ", fn s ->
            "#{inspect(s.scorer)}: #{Float.round(s.score, 2)}"
          end)

        "  #{status} #{r.case_name} (#{Float.round(r.aggregate_score, 3)}) [#{scores}]"
      end)
      |> Enum.join("\n")

    header <> details
  end
end
