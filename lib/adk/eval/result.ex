defmodule ADK.Eval.Result do
  @moduledoc "Result of evaluating a single test case."

  @type t :: %__MODULE__{
          case_name: String.t(),
          pass: boolean(),
          scores: [
            %{scorer: module(), score: float(), pass: boolean(), details: String.t() | nil}
          ],
          aggregate_score: float(),
          events: [ADK.Event.t()],
          duration_ms: non_neg_integer()
        }

  defstruct [:case_name, :pass, :aggregate_score, :duration_ms, scores: [], events: []]
end
