defmodule ADK.EvalTest do
  use ExUnit.Case, async: true

  alias ADK.Eval
  alias ADK.Eval.{Case, Report}
  alias ADK.Eval.Scorer.{ExactMatch, Contains, ResponseLength, ToolUsed}

  # Helper to create mock events simulating agent responses
  defp text_events(text) do
    [
      ADK.Event.new(%{
        author: "agent",
        content: %{parts: [%{text: text}]}
      })
    ]
  end

  defp tool_call_events(tool_name, args \\ %{}) do
    [
      ADK.Event.new(%{
        author: "agent",
        content: %{
          parts: [%{function_call: %{name: tool_name, args: args}}]
        }
      }),
      ADK.Event.new(%{
        author: "agent",
        content: %{parts: [%{text: "Done"}]}
      })
    ]
  end

  describe "Scorer.ExactMatch" do
    test "passes on exact match" do
      assert %{pass: true, score: 1.0} =
               ExactMatch.score(text_events("Hello!"), expected: "Hello!")
    end

    test "fails on mismatch" do
      assert %{pass: false, score: 0.0} =
               ExactMatch.score(text_events("Hi!"), expected: "Hello!")
    end
  end

  describe "Scorer.Contains" do
    test "passes when text contains substring" do
      assert %{pass: true} =
               Contains.score(text_events("Hello world!"), text: "world")
    end

    test "case insensitive" do
      assert %{pass: true} =
               Contains.score(text_events("Hello World"), text: "hello", case_sensitive: false)
    end

    test "fails when not found" do
      assert %{pass: false} =
               Contains.score(text_events("Goodbye"), text: "hello")
    end
  end

  describe "Scorer.ResponseLength" do
    test "passes within range" do
      assert %{pass: true} =
               ResponseLength.score(text_events("Hello"), min: 1, max: 100)
    end

    test "fails when too short" do
      assert %{pass: false} =
               ResponseLength.score(text_events("Hi"), min: 10)
    end

    test "fails when too long" do
      assert %{pass: false} =
               ResponseLength.score(text_events(String.duplicate("x", 200)), max: 100)
    end
  end

  describe "Scorer.ToolUsed" do
    test "passes when tool was called" do
      assert %{pass: true} =
               ToolUsed.score(tool_call_events("search"), name: "search")
    end

    test "fails when tool was not called" do
      assert %{pass: false} =
               ToolUsed.score(text_events("No tools used"), name: "search")
    end
  end

  describe "Eval.Case" do
    test "creates a case struct" do
      c = Case.new(name: "test", input: "hi", scorers: [{Contains, text: "hello"}])
      assert c.name == "test"
      assert c.input == "hi"
      assert length(c.scorers) == 1
    end
  end

  describe "Report.format/1" do
    test "formats a report" do
      report = %Report{
        total: 2,
        passed: 1,
        failed: 1,
        average_score: 0.5,
        duration_ms: 100,
        results: [
          %ADK.Eval.Result{
            case_name: "a",
            pass: true,
            aggregate_score: 1.0,
            scores: [%{scorer: Contains, score: 1.0, pass: true, details: nil}],
            events: [],
            duration_ms: 50
          },
          %ADK.Eval.Result{
            case_name: "b",
            pass: false,
            aggregate_score: 0.0,
            scores: [%{scorer: Contains, score: 0.0, pass: false, details: "nope"}],
            events: [],
            duration_ms: 50
          }
        ]
      }

      formatted = Report.format(report)
      assert formatted =~ "1/2 passed"
      assert formatted =~ "✅ a"
      assert formatted =~ "❌ b"
    end
  end
end
