defmodule ADK.Eval.Scorer.ResponseLength do
  @moduledoc "Scores based on whether response length is within a min/max character range."
  @behaviour ADK.Eval.Scorer

  @impl true
  def score(events, opts) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, :infinity)

    len = events |> ADK.Eval.Scorer.response_text() |> String.length()

    cond do
      len < min ->
        %{score: 0.0, pass: false, details: "Response too short: #{len} < #{min}"}

      max != :infinity and len > max ->
        %{score: 0.0, pass: false, details: "Response too long: #{len} > #{max}"}

      true ->
        %{score: 1.0, pass: true, details: "Length #{len} within range"}
    end
  end
end
