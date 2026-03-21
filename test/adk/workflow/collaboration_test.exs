defmodule ADK.Workflow.CollaborationTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow.Collaboration

  defp make_events(author, text) do
    [ADK.Event.new(author: author, content: %{"parts" => [%{"text" => text}]})]
  end

  defp make_ctx do
    %ADK.Context{invocation_id: "collab-test"}
  end

  describe "pipeline mode" do
    test "flattens all events in order" do
      results = [
        {"agent_a", make_events("agent_a", "first")},
        {"agent_b", make_events("agent_b", "second")}
      ]

      %{events: events, output: output} = Collaboration.combine(:pipeline, results, make_ctx())
      assert length(events) == 2
      assert output == "second"
    end

    test "handles empty results" do
      %{events: events, output: output} = Collaboration.combine(:pipeline, [], make_ctx())
      assert events == []
      assert output == nil
    end
  end

  describe "debate mode" do
    test "creates synthesis with all positions" do
      results = [
        {"optimist", make_events("optimist", "Everything is great!")},
        {"pessimist", make_events("pessimist", "Everything is terrible!")}
      ]

      %{events: events, output: output} = Collaboration.combine(:debate, results, make_ctx())

      # Should include original events + synthesis
      assert length(events) == 3
      assert output =~ "optimist"
      assert output =~ "pessimist"

      # Synthesis event
      synthesis = List.last(events)
      assert synthesis.author == "debate_synthesis"
      assert ADK.Event.text(synthesis) =~ "Debate Results"
    end
  end

  describe "vote mode" do
    test "picks majority answer" do
      results = [
        {"voter_1", make_events("voter_1", "yes")},
        {"voter_2", make_events("voter_2", "no")},
        {"voter_3", make_events("voter_3", "yes")}
      ]

      %{events: events, output: winner} = Collaboration.combine(:vote, results, make_ctx())
      assert winner == "yes"

      # Should have vote_result event
      vote_event = Enum.find(events, fn e -> e.author == "vote_result" end)
      assert vote_event != nil
      assert vote_event.custom_metadata["winner"] == "yes"
    end

    test "handles tie (picks one)" do
      results = [
        {"voter_1", make_events("voter_1", "alpha")},
        {"voter_2", make_events("voter_2", "beta")}
      ]

      %{output: winner} = Collaboration.combine(:vote, results, make_ctx())
      assert winner in ["alpha", "beta"]
    end

    test "handles empty votes" do
      %{output: winner} = Collaboration.combine(:vote, [], make_ctx())
      assert winner == nil
    end
  end

  describe "review mode" do
    test "first result is production, rest are reviews" do
      results = [
        {"writer", make_events("writer", "Draft article about AI")},
        {"editor", make_events("editor", "Needs more examples")},
        {"fact_checker", make_events("fact_checker", "Claims verified")}
      ]

      %{events: events, output: output} =
        Collaboration.combine(:review, results, make_ctx())

      assert output == "Draft article about AI"

      # Should have review events
      review_events = Enum.filter(events, fn e ->
        text = ADK.Event.text(e)
        text != nil and String.contains?(text, "Review of")
      end)

      assert length(review_events) == 2
    end

    test "handles single producer with no reviewers" do
      results = [{"solo", make_events("solo", "Solo work")}]

      %{events: events, output: output} =
        Collaboration.combine(:review, results, make_ctx())

      assert output == "Solo work"
      assert length(events) == 1
    end

    test "handles empty results" do
      %{events: events, output: output} =
        Collaboration.combine(:review, [], make_ctx())

      assert events == []
      assert output == nil
    end
  end
end
