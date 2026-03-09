defmodule ADK.Eval.Scorer.ToolUsed do
  @moduledoc "Scores 1.0 if the agent called a specific tool (function) by name."
  @behaviour ADK.Eval.Scorer

  @impl true
  def score(events, opts) do
    tool_name = Keyword.fetch!(opts, :name)

    calls = ADK.Eval.Scorer.function_calls(events)

    found =
      Enum.any?(calls, fn
        %{function_call: %{name: ^tool_name}} -> true
        %{function_call: %{"name" => ^tool_name}} -> true
        _ -> false
      end)

    if found do
      %{score: 1.0, pass: true, details: nil}
    else
      names = Enum.map(calls, fn %{function_call: fc} -> fc[:name] || fc["name"] end)
      %{score: 0.0, pass: false, details: "Tool #{tool_name} not called. Called: #{inspect(names)}"}
    end
  end
end
