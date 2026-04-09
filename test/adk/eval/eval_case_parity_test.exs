defmodule ADK.Eval.EvalCaseParityTest do
  @moduledoc """
  Parity tests for eval infrastructure, ported from Python ADK's
  `tests/unittests/cli/utils/test_evals.py` and
  `tests/unittests/evaluation/test_eval_case.py`.

  Python `test_evals.py` (2 tests) tests GCS URI parsing for eval set
  managers — pure Python CLI plumbing with no Elixir equivalent. Skipped.

  Python `test_eval_case.py` tests tool call/response extraction from events
  and eval case validation. Those behavioral patterns map to:
    - `ADK.Event.function_calls/1` (string-key content)
    - `ADK.Event.function_responses/1` (string-key content)
    - `ADK.Eval.Scorer.function_calls/1` (atom-key content)
    - `ADK.Eval.Scorer.response_text/1` (atom-key content)
    - `ADK.Eval.Case` struct creation and validation
    - `ADK.Eval.Report.format/1`
    - End-to-end `ADK.Eval.run/3` pipeline
  """

  use ExUnit.Case, async: true

  alias ADK.Eval
  alias ADK.Eval.{Case, Report, Result}
  alias ADK.Eval.Scorer
  alias ADK.Eval.Scorer.{Contains, ExactMatch, ResponseLength, ToolUsed}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Scorer functions use atom-key content (%{parts: [%{text: ...}]}).
  defp scorer_event(text, author \\ "agent") do
    ADK.Event.new(%{
      author: author,
      partial: false,
      content: %{parts: [%{text: text}]}
    })
  end

  defp scorer_tool_call_event(name, args \\ %{}) do
    ADK.Event.new(%{
      author: "agent",
      partial: false,
      content: %{parts: [%{function_call: %{name: name, args: args}}]}
    })
  end

  # Event functions (function_calls, function_responses) use string-key
  # content (%{"parts" => [%{"function_call" => ...}]}).
  defp string_key_text_event(text) do
    ADK.Event.new(%{
      author: "agent",
      partial: false,
      content: %{"parts" => [%{"text" => text}]}
    })
  end

  defp string_key_tool_call_event(name, args) do
    ADK.Event.new(%{
      author: "agent",
      partial: false,
      content: %{"parts" => [%{"function_call" => %{"name" => name, "args" => args}}]}
    })
  end

  defp string_key_tool_response_event(name, response) do
    ADK.Event.new(%{
      author: "tool",
      partial: false,
      content: %{"parts" => [%{"function_response" => %{"name" => name, "response" => response}}]}
    })
  end

  defp string_key_mixed_event(parts) do
    ADK.Event.new(%{
      author: "agent",
      partial: false,
      content: %{"parts" => parts}
    })
  end

  defp scorer_mixed_event(parts) do
    ADK.Event.new(%{
      author: "agent",
      partial: false,
      content: %{parts: parts}
    })
  end

  # ---------------------------------------------------------------------------
  # Event.function_calls/1 — tool call extraction (string keys)
  # Parity with Python test_get_all_tool_calls_*
  # ---------------------------------------------------------------------------

  describe "Event.function_calls/1 - tool call extraction" do
    test "returns empty list when event has no tool calls" do
      event = string_key_text_event("Thinking...")
      assert ADK.Event.function_calls(event) == []
    end

    test "extracts single function call" do
      event = string_key_tool_call_event("search", %{"query" => "weather"})
      calls = ADK.Event.function_calls(event)
      assert length(calls) == 1
      assert hd(calls)["name"] == "search"
    end

    test "extracts function calls from mixed content" do
      event =
        string_key_mixed_event([
          %{"text" => "Found something."},
          %{"function_call" => %{"name" => "lookup", "args" => %{"id" => "123"}}}
        ])

      calls = ADK.Event.function_calls(event)
      assert length(calls) == 1
      assert hd(calls)["name"] == "lookup"
    end

    test "extracts multiple function calls from single event" do
      event =
        string_key_mixed_event([
          %{"function_call" => %{"name" => "search", "args" => %{"q" => "weather"}}},
          %{"function_call" => %{"name" => "lookup", "args" => %{"id" => "123"}}}
        ])

      calls = ADK.Event.function_calls(event)
      assert length(calls) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Event.function_responses/1 — tool response extraction (string keys)
  # Parity with Python test_get_all_tool_responses_*
  # ---------------------------------------------------------------------------

  describe "Event.function_responses/1 - tool response extraction" do
    test "returns empty list when event has no tool responses" do
      event = string_key_text_event("No tools used")
      assert ADK.Event.function_responses(event) == []
    end

    test "extracts function response" do
      event = string_key_tool_response_event("search", %{"result" => "sunny"})
      responses = ADK.Event.function_responses(event)
      assert length(responses) == 1
      assert hd(responses)["name"] == "search"
    end

    test "extracts responses from mixed content" do
      event =
        ADK.Event.new(%{
          author: "tool",
          partial: false,
          content: %{
            "parts" => [
              %{"text" => "Found something."},
              %{"function_response" => %{"name" => "lookup", "response" => %{"id" => "123"}}}
            ]
          }
        })

      responses = ADK.Event.function_responses(event)
      assert length(responses) == 1
      assert hd(responses)["name"] == "lookup"
    end
  end

  # ---------------------------------------------------------------------------
  # Scorer.function_calls/1 — across multiple events (atom keys)
  # ---------------------------------------------------------------------------

  describe "Scorer.function_calls/1 - cross-event extraction" do
    test "returns empty list for no events" do
      assert Scorer.function_calls([]) == []
    end

    test "returns empty list for text-only events" do
      events = [scorer_event("Hello"), scorer_event("World")]
      assert Scorer.function_calls(events) == []
    end

    test "extracts calls across multiple events" do
      events = [
        scorer_tool_call_event("search", %{"q" => "weather"}),
        scorer_event("processing..."),
        scorer_tool_call_event("lookup", %{"id" => "123"})
      ]

      calls = Scorer.function_calls(events)
      assert length(calls) == 2
    end

    test "extracts calls from events with mixed parts" do
      events = [
        scorer_mixed_event([
          %{text: "Let me search"},
          %{function_call: %{name: "search", args: %{}}}
        ]),
        scorer_mixed_event([
          %{function_call: %{name: "lookup", args: %{}}},
          %{text: "Also looking up"}
        ])
      ]

      calls = Scorer.function_calls(events)
      assert length(calls) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Scorer.response_text/1 (atom keys)
  # ---------------------------------------------------------------------------

  describe "Scorer.response_text/1" do
    test "returns empty string for no events" do
      assert Scorer.response_text([]) == ""
    end

    test "concatenates text from multiple events" do
      events = [scorer_event("Hello"), scorer_event(" World")]
      assert Scorer.response_text(events) == "Hello World"
    end

    test "skips user events" do
      events = [
        scorer_event("user input", "user"),
        scorer_event("agent reply", "agent")
      ]

      assert Scorer.response_text(events) == "agent reply"
    end

    test "skips partial events" do
      events = [
        ADK.Event.new(%{author: "agent", partial: true, content: %{parts: [%{text: "par"}]}}),
        scorer_event("full response")
      ]

      assert Scorer.response_text(events) == "full response"
    end

    test "ignores non-text parts" do
      events = [
        scorer_mixed_event([
          %{function_call: %{name: "search", args: %{}}},
          %{text: "result"}
        ])
      ]

      assert Scorer.response_text(events) == "result"
    end

    test "handles events with nil content" do
      events = [ADK.Event.new(%{author: "agent", partial: false, content: nil})]
      assert Scorer.response_text(events) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Eval.Case struct (parity with EvalCase validation tests)
  # ---------------------------------------------------------------------------

  describe "Eval.Case" do
    test "creates case with required fields" do
      c = Case.new(name: "test", input: "hello")
      assert c.name == "test"
      assert c.input == "hello"
      assert c.scorers == []
      assert c.metadata == %{}
    end

    test "creates case with scorers" do
      c =
        Case.new(
          name: "test",
          input: "hi",
          scorers: [
            {Contains, text: "hello"},
            {ResponseLength, min: 1, max: 500}
          ]
        )

      assert length(c.scorers) == 2
    end

    test "creates case with metadata" do
      c = Case.new(name: "test", input: "hi", metadata: %{category: "basic"})
      assert c.metadata == %{category: "basic"}
    end

    test "raises on missing name" do
      assert_raise KeyError, fn ->
        Case.new(input: "hi")
      end
    end

    test "raises on missing input" do
      assert_raise KeyError, fn ->
        Case.new(name: "test")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scorers — comprehensive (parity ensures scorers behave like Python metrics)
  # ---------------------------------------------------------------------------

  describe "Scorer.ExactMatch" do
    test "passes on exact match" do
      assert %{pass: true, score: 1.0} =
               ExactMatch.score([scorer_event("Hello!")], expected: "Hello!")
    end

    test "fails on mismatch" do
      assert %{pass: false, score: +0.0} =
               ExactMatch.score([scorer_event("Hi!")], expected: "Hello!")
    end

    test "fails on empty response" do
      assert %{pass: false} = ExactMatch.score([], expected: "something")
    end

    test "matches concatenated multi-event text" do
      events = [scorer_event("Hello"), scorer_event(" World")]
      assert %{pass: true} = ExactMatch.score(events, expected: "Hello World")
    end
  end

  describe "Scorer.Contains" do
    test "passes when text contains substring" do
      assert %{pass: true} = Contains.score([scorer_event("Hello world!")], text: "world")
    end

    test "case insensitive match" do
      assert %{pass: true} =
               Contains.score([scorer_event("Hello World")], text: "hello", case_sensitive: false)
    end

    test "fails when not found" do
      assert %{pass: false} = Contains.score([scorer_event("Goodbye")], text: "hello")
    end

    test "case sensitive by default" do
      assert %{pass: false} = Contains.score([scorer_event("Hello")], text: "hello")
    end
  end

  describe "Scorer.ResponseLength" do
    test "passes within range" do
      assert %{pass: true} = ResponseLength.score([scorer_event("Hello")], min: 1, max: 100)
    end

    test "fails when too short" do
      assert %{pass: false} = ResponseLength.score([scorer_event("Hi")], min: 10)
    end

    test "fails when too long" do
      long_text = String.duplicate("x", 200)
      assert %{pass: false} = ResponseLength.score([scorer_event(long_text)], max: 100)
    end

    test "passes with no bounds" do
      assert %{pass: true} = ResponseLength.score([scorer_event("anything")], [])
    end
  end

  describe "Scorer.ToolUsed" do
    test "passes when tool was called" do
      events = [scorer_tool_call_event("search", %{"q" => "weather"}), scorer_event("Done")]
      assert %{pass: true} = ToolUsed.score(events, name: "search")
    end

    test "fails when tool was not called" do
      assert %{pass: false} = ToolUsed.score([scorer_event("No tools")], name: "search")
    end

    test "fails when different tool was called" do
      events = [scorer_tool_call_event("lookup"), scorer_event("Done")]
      assert %{pass: false} = ToolUsed.score(events, name: "search")
    end

    test "passes with string-key function call" do
      event =
        ADK.Event.new(%{
          author: "agent",
          partial: false,
          content: %{parts: [%{function_call: %{"name" => "search", "args" => %{}}}]}
        })

      assert %{pass: true} = ToolUsed.score([event], name: "search")
    end
  end

  # ---------------------------------------------------------------------------
  # Report formatting
  # ---------------------------------------------------------------------------

  describe "Report.format/1" do
    test "formats a passing report" do
      report = %Report{
        total: 1,
        passed: 1,
        failed: 0,
        average_score: 1.0,
        duration_ms: 42,
        results: [
          %Result{
            case_name: "greeting",
            pass: true,
            aggregate_score: 1.0,
            scores: [%{scorer: Contains, score: 1.0, pass: true, details: nil}],
            events: [],
            duration_ms: 42
          }
        ]
      }

      formatted = Report.format(report)
      assert formatted =~ "1/1 passed"
      assert formatted =~ "✅ greeting"
    end

    test "formats a mixed report" do
      report = %Report{
        total: 2,
        passed: 1,
        failed: 1,
        average_score: 0.5,
        duration_ms: 100,
        results: [
          %Result{
            case_name: "pass_case",
            pass: true,
            aggregate_score: 1.0,
            scores: [%{scorer: ExactMatch, score: 1.0, pass: true, details: nil}],
            events: [],
            duration_ms: 50
          },
          %Result{
            case_name: "fail_case",
            pass: false,
            aggregate_score: +0.0,
            scores: [%{scorer: ExactMatch, score: +0.0, pass: false, details: "mismatch"}],
            events: [],
            duration_ms: 50
          }
        ]
      }

      formatted = Report.format(report)
      assert formatted =~ "1/2 passed"
      assert formatted =~ "✅ pass_case"
      assert formatted =~ "❌ fail_case"
    end

    test "formats empty report" do
      report = %Report{
        total: 0,
        passed: 0,
        failed: 0,
        average_score: +0.0,
        duration_ms: 0,
        results: []
      }

      formatted = Report.format(report)
      assert formatted =~ "0/0 passed"
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end Eval.run/3 (integration of case → runner → scoring → report)
  # ---------------------------------------------------------------------------

  describe "Eval.run/3 end-to-end" do
    test "runs eval cases against a custom agent and produces report" do
      agent =
        ADK.Agent.Custom.new(
          name: "greeter",
          run_fn: fn _agent, _ctx ->
            [
              ADK.Event.new(%{
                author: "greeter",
                partial: false,
                content: %{parts: [%{text: "Hello friend!"}]}
              })
            ]
          end
        )

      runner = ADK.Runner.new(app_name: "eval_test", agent: agent)

      cases = [
        Case.new(
          name: "contains_hello",
          input: "Say hi",
          scorers: [{Contains, text: "Hello", case_sensitive: false}]
        ),
        Case.new(
          name: "exact_mismatch",
          input: "Say hi",
          scorers: [{ExactMatch, expected: "Wrong answer"}]
        )
      ]

      report = Eval.run(runner, cases)

      assert %Report{} = report
      assert report.total == 2
      assert report.passed == 1
      assert report.failed == 1
      assert length(report.results) == 2

      [pass_result, fail_result] = report.results
      assert pass_result.pass == true
      assert pass_result.case_name == "contains_hello"
      assert fail_result.pass == false
      assert fail_result.case_name == "exact_mismatch"
    end

    test "empty case list produces empty report" do
      agent =
        ADK.Agent.Custom.new(
          name: "noop",
          run_fn: fn _agent, _ctx -> [] end
        )

      runner = ADK.Runner.new(app_name: "eval_test", agent: agent)
      report = Eval.run(runner, [])

      assert report.total == 0
      assert report.passed == 0
      assert report.failed == 0
      assert report.average_score == +0.0
    end

    test "case with no scorers passes by default" do
      agent =
        ADK.Agent.Custom.new(
          name: "echo",
          run_fn: fn _agent, _ctx ->
            [ADK.Event.new(%{author: "echo", partial: false, content: %{parts: [%{text: "ok"}]}})]
          end
        )

      runner = ADK.Runner.new(app_name: "eval_test", agent: agent)

      cases = [Case.new(name: "no_scorers", input: "test")]
      report = Eval.run(runner, cases)

      assert report.total == 1
      assert report.passed == 1
      assert hd(report.results).aggregate_score == 1.0
    end

    test "threshold controls pass/fail" do
      agent =
        ADK.Agent.Custom.new(
          name: "half",
          run_fn: fn _agent, _ctx ->
            [
              ADK.Event.new(%{
                author: "half",
                partial: false,
                content: %{parts: [%{text: "Hello there"}]}
              })
            ]
          end
        )

      runner = ADK.Runner.new(app_name: "eval_test", agent: agent)

      cases = [
        Case.new(
          name: "partial_match",
          input: "test",
          scorers: [
            {Contains, text: "Hello"},
            {ExactMatch, expected: "wrong"}
          ]
        )
      ]

      # With threshold 1.0 (default), avg 0.5 < 1.0 → fail
      report_strict = Eval.run(runner, cases, threshold: 1.0)
      assert hd(report_strict.results).pass == false

      # With threshold 0.5, avg 0.5 >= 0.5 → pass
      report_lenient = Eval.run(runner, cases, threshold: 0.5)
      assert hd(report_lenient.results).pass == true
    end

    test "multiple scorers produce aggregate score" do
      agent =
        ADK.Agent.Custom.new(
          name: "multi",
          run_fn: fn _agent, _ctx ->
            [
              ADK.Event.new(%{
                author: "multi",
                partial: false,
                content: %{parts: [%{text: "Hello world, this is a test response."}]}
              })
            ]
          end
        )

      runner = ADK.Runner.new(app_name: "eval_test", agent: agent)

      cases = [
        Case.new(
          name: "multi_scorer",
          input: "test",
          scorers: [
            {Contains, text: "Hello"},
            {Contains, text: "world"},
            {ResponseLength, min: 10, max: 200}
          ]
        )
      ]

      report = Eval.run(runner, cases)
      result = hd(report.results)
      assert result.pass == true
      assert result.aggregate_score == 1.0
      assert length(result.scores) == 3
    end

    test "report includes duration" do
      agent =
        ADK.Agent.Custom.new(
          name: "slow",
          run_fn: fn _agent, _ctx ->
            [ADK.Event.new(%{author: "slow", partial: false, content: %{parts: [%{text: "ok"}]}})]
          end
        )

      runner = ADK.Runner.new(app_name: "eval_test", agent: agent)
      cases = [Case.new(name: "dur", input: "x")]

      report = Eval.run(runner, cases)
      assert report.duration_ms >= 0
      assert hd(report.results).duration_ms >= 0
    end
  end
end
