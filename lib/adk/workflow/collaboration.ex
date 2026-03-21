defmodule ADK.Workflow.Collaboration do
  @moduledoc """
  Collaboration modes for workflow fan-out nodes.

  When multiple agents process at a join point, the collaboration mode
  determines how their outputs are combined.

  ## Modes

  - `:pipeline` — output of each feeds into the next sequentially (default)
  - `:debate` — all process same input, results are compared/synthesized
  - `:vote` — all process same input, majority answer wins
  - `:review` — first produces, subsequent review/critique the output
  """

  @type mode :: :pipeline | :debate | :vote | :review
  @type result :: %{events: [ADK.Event.t()], output: any()}

  @doc """
  Combine results from multiple agents using the given collaboration mode.

  ## Parameters

  - `mode` — collaboration strategy
  - `results` — list of `{agent_name, events}` tuples from each agent
  - `ctx` — the workflow context
  """
  @spec combine(mode(), [{String.t(), [ADK.Event.t()]}], ADK.Context.t()) :: result()
  def combine(:pipeline, results, _ctx) do
    # Pipeline: events are already sequential, just flatten
    all_events = Enum.flat_map(results, fn {_name, events} -> events end)
    output = last_text(all_events)
    %{events: all_events, output: output}
  end

  def combine(:debate, results, _ctx) do
    # Debate: collect all outputs, create a synthesis event
    positions =
      results
      |> Enum.map(fn {name, events} ->
        text = last_text(events) || "(no response)"
        "**#{name}**: #{text}"
      end)
      |> Enum.join("\n\n")

    synthesis = ADK.Event.new(
      author: "debate_synthesis",
      content: %{
        "parts" => [%{"text" => "## Debate Results\n\n#{positions}"}]
      }
    )

    all_events = Enum.flat_map(results, fn {_name, events} -> events end)
    %{events: all_events ++ [synthesis], output: positions}
  end

  def combine(:vote, results, _ctx) do
    # Vote: tally text outputs, majority wins
    votes =
      results
      |> Enum.map(fn {_name, events} -> last_text(events) end)
      |> Enum.reject(&is_nil/1)

    winner =
      votes
      |> Enum.frequencies()
      |> Enum.max_by(fn {_text, count} -> count end, fn -> {nil, 0} end)
      |> elem(0)

    vote_event = ADK.Event.new(
      author: "vote_result",
      content: %{
        "parts" => [%{"text" => winner || "(no consensus)"}]
      },
      custom_metadata: %{
        "votes" => Enum.frequencies(votes),
        "winner" => winner
      }
    )

    all_events = Enum.flat_map(results, fn {_name, events} -> events end)
    %{events: all_events ++ [vote_event], output: winner}
  end

  def combine(:review, results, _ctx) do
    # Review: first result is the production, rest are reviews
    case results do
      [] ->
        %{events: [], output: nil}

      [{producer_name, producer_events} | reviewers] ->
        produced = last_text(producer_events) || "(no output)"

        review_events =
          reviewers
          |> Enum.map(fn {reviewer_name, events} ->
            review_text = last_text(events) || "(no review)"

            ADK.Event.new(
              author: reviewer_name,
              content: %{
                "parts" => [
                  %{"text" => "## Review of #{producer_name}'s output\n\n#{review_text}"}
                ]
              }
            )
          end)

        all_events =
          producer_events ++
            Enum.flat_map(reviewers, fn {_name, events} -> events end) ++
            review_events

        %{events: all_events, output: produced}
    end
  end

  # Extract the last text content from a list of events
  defp last_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&ADK.Event.text/1)
  end
end
