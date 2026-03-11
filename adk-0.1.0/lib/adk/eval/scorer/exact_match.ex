defmodule ADK.Eval.Scorer.ExactMatch do
  @moduledoc "Scores 1.0 if the response text exactly matches the expected text."
  @behaviour ADK.Eval.Scorer

  @impl true
  def score(events, opts) do
    expected = Keyword.fetch!(opts, :expected)
    actual = ADK.Eval.Scorer.response_text(events)

    if actual == expected do
      %{score: 1.0, pass: true, details: nil}
    else
      %{score: 0.0, pass: false, details: "Expected #{inspect(expected)}, got #{inspect(actual)}"}
    end
  end
end
