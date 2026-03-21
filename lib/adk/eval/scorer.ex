defmodule ADK.Eval.Scorer do
  @moduledoc """
  Behaviour for evaluation scorers.

  A scorer examines an agent's response (list of events) and returns a score
  between 0.0 and 1.0, along with a pass/fail determination and details.

  ## Implementing a custom scorer

      defmodule MyScorer do
        @behaviour ADK.Eval.Scorer

        @impl true
        def score(events, opts) do
          # ... analyze events ...
          %{score: 1.0, pass: true, details: "looks good"}
        end
      end
  """

  @type score_result :: %{
          score: float(),
          pass: boolean(),
          details: String.t() | nil
        }

  @callback score(events :: [ADK.Event.t()], opts :: keyword()) :: score_result()

  @doc "Extract all text from agent response events (non-user, non-partial)."
  @spec response_text([ADK.Event.t()]) :: String.t()
  def response_text(events) do
    events
    |> Enum.filter(fn e -> e.author != "user" and !e.partial end)
    |> Enum.flat_map(fn e ->
      case e.content do
        %{parts: parts} when is_list(parts) ->
          Enum.map(parts, fn
            %{text: t} when is_binary(t) -> t
            _ -> ""
          end)

        _ ->
          []
      end
    end)
    |> Enum.join("")
  end

  @doc "Extract all function calls from events."
  @spec function_calls([ADK.Event.t()]) :: [map()]
  def function_calls(events) do
    events
    |> Enum.flat_map(fn e ->
      case e.content do
        %{parts: parts} when is_list(parts) ->
          Enum.filter(parts, &match?(%{function_call: _}, &1))

        _ ->
          []
      end
    end)
  end
end
