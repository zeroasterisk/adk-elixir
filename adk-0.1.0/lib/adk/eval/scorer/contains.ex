defmodule ADK.Eval.Scorer.Contains do
  @moduledoc "Scores 1.0 if the response text contains the given substring."
  @behaviour ADK.Eval.Scorer

  @impl true
  def score(events, opts) do
    text = Keyword.fetch!(opts, :text)
    case_sensitive = Keyword.get(opts, :case_sensitive, true)

    actual = ADK.Eval.Scorer.response_text(events)

    {haystack, needle} =
      if case_sensitive do
        {actual, text}
      else
        {String.downcase(actual), String.downcase(text)}
      end

    if String.contains?(haystack, needle) do
      %{score: 1.0, pass: true, details: nil}
    else
      %{score: 0.0, pass: false, details: "Response does not contain #{inspect(text)}"}
    end
  end
end
