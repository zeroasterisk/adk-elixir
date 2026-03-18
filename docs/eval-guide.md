# ADK Elixir — Evaluation Guide

How to write and run quality evaluations against your agents using `ADK.Eval`.

---

## Overview

`ADK.Eval` provides a lightweight evaluation framework:

1. Define **cases** — input messages + expected behaviour
2. Attach **scorers** — functions that grade the response
3. Run against a **Runner** — get a **Report** back

This mirrors the `pytest`-style eval patterns from Python ADK, but uses plain
Elixir data structures and `ExUnit` (or standalone scripts).

---

## Quick Start

```elixir
alias ADK.Eval
alias ADK.Eval.{Case, Scorer}
alias ADK.{Runner, Agent.LlmAgent}

# 1. Build your agent
agent = LlmAgent.new(
  name: "assistant",
  model: "gemini-2.0-flash",
  instruction: "You are a helpful assistant."
)

# 2. Build a runner
runner = Runner.new(app_name: "eval_run", agent: agent)

# 3. Define eval cases
cases = [
  Case.new(
    name: "greeting",
    input: "Say hello",
    scorers: [
      {Scorer.Contains, text: "hello", case_sensitive: false},
      {Scorer.ResponseLength, min: 1, max: 500}
    ]
  ),
  Case.new(
    name: "capital_of_france",
    input: "What is the capital of France?",
    scorers: [
      {Scorer.Contains, text: "Paris"}
    ]
  )
]

# 4. Run
report = Eval.run(runner, cases)
IO.puts(Eval.Report.format(report))
```

Sample output:

```
Eval Report: 2/2 passed (avg score: 1.0)
  ✅ greeting (1.0) [Scorer.Contains: 1.0, Scorer.ResponseLength: 1.0]
  ✅ capital_of_france (1.0) [Scorer.Contains: 1.0]
```

---

## Eval Cases — `ADK.Eval.Case`

```elixir
%ADK.Eval.Case{
  name: "my_test",         # required — unique name for the case
  input: "User message",   # required — sent to the agent
  scorers: [               # list of {module, opts} tuples
    {Scorer.Contains, text: "expected"},
    {Scorer.ResponseLength, min: 5, max: 1000}
  ],
  metadata: %{category: "smoke"}  # optional — free-form tags
}
```

---

## Built-in Scorers

All scorers live in `ADK.Eval.Scorer.*` and implement the `ADK.Eval.Scorer` behaviour.

### `Scorer.Contains`

Check that the response contains a substring.

```elixir
{Scorer.Contains, text: "Paris"}
{Scorer.Contains, text: "hello", case_sensitive: false}
```

### `Scorer.ExactMatch`

Check that the response exactly matches a string (trimmed, case-sensitive by default).

```elixir
{Scorer.ExactMatch, expected: "Yes"}
{Scorer.ExactMatch, expected: "yes", case_sensitive: false}
```

### `Scorer.ResponseLength`

Check that response length is within bounds.

```elixir
{Scorer.ResponseLength, min: 10}
{Scorer.ResponseLength, max: 500}
{Scorer.ResponseLength, min: 20, max: 200}
```

### `Scorer.ToolUsed`

Check that the agent called a specific tool.

```elixir
{Scorer.ToolUsed, tool_name: "get_weather"}
```

---

## Custom Scorers

Implement `ADK.Eval.Scorer` for custom grading logic:

```elixir
defmodule MyApp.Evals.Scorer.Polite do
  @behaviour ADK.Eval.Scorer

  @impl true
  def score(events, _opts) do
    text = ADK.Eval.Scorer.response_text(events)
    pass = String.contains?(text, ["please", "thank", "sorry"])
    %{score: if(pass, do: 1.0, else: 0.0), pass: pass, details: text}
  end
end
```

Usage:

```elixir
{MyApp.Evals.Scorer.Polite, []}
```

---

## Run Options

```elixir
report = Eval.run(runner, cases,
  threshold: 0.8,      # aggregate score to pass a case (default: 1.0)
  user_id: "eval_bot"  # user ID for sessions (default: "eval_user")
)
```

---

## Report — `ADK.Eval.Report`

```elixir
%ADK.Eval.Report{
  total: 5,
  passed: 4,
  failed: 1,
  average_score: 0.9,
  duration_ms: 1234,
  results: [...]   # list of ADK.Eval.Result structs
}

# Human-readable summary
IO.puts(ADK.Eval.Report.format(report))

# Programmatic access
Enum.each(report.results, fn result ->
  IO.puts("#{result.case_name}: #{if result.pass, do: "PASS", else: "FAIL"}")
  IO.puts("  Score: #{result.aggregate_score}")
  IO.puts("  Duration: #{result.duration_ms}ms")
end)
```

---

## Running Evals in ExUnit

Evals integrate naturally into ExUnit for CI:

```elixir
defmodule MyApp.AgentEvalTest do
  use ExUnit.Case

  alias ADK.Eval
  alias ADK.Eval.{Case, Scorer}

  setup_all do
    agent = MyApp.build_agent()
    runner = ADK.Runner.new(app_name: "eval", agent: agent)
    %{runner: runner}
  end

  @cases [
    Case.new(
      name: "greeting",
      input: "Hello",
      scorers: [{Scorer.ResponseLength, min: 1}]
    ),
    Case.new(
      name: "tool_call",
      input: "What's the weather in London?",
      scorers: [{Scorer.ToolUsed, tool_name: "get_weather"}]
    )
  ]

  test "all eval cases pass", %{runner: runner} do
    report = Eval.run(runner, @cases)

    failed = Enum.filter(report.results, &(not &1.pass))
    assert failed == [], fn ->
      "Eval failures:\n" <> Enum.map_join(failed, "\n", fn r ->
        "  #{r.case_name}: score=#{r.aggregate_score}"
      end)
    end
  end
end
```

Run:

```bash
mix test test/my_app/agent_eval_test.exs --trace
```

---

## Loading Cases from Files

For larger eval suites, store cases as JSON or YAML and load them:

```elixir
# eval/cases/basic.json
# [{"name": "greeting", "input": "Hello", "scorers": [["contains", {"text": "hi"}]]}]

defmodule MyApp.EvalLoader do
  def load(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(&build_case/1)
  end

  defp build_case(%{"name" => name, "input" => input, "scorers" => scorers}) do
    ADK.Eval.Case.new(
      name: name,
      input: input,
      scorers: Enum.map(scorers, &parse_scorer/1)
    )
  end

  defp parse_scorer(["contains", opts]) do
    {ADK.Eval.Scorer.Contains, Map.to_list(opts)}
  end
  # add more scorer parsers as needed
end
```

---

## Tips

- **Isolate eval sessions**: each case gets a unique `session_id` automatically — no bleed between cases.
- **Threshold tuning**: start with `threshold: 1.0` for hard requirements; use lower values for probabilistic scorers.
- **Parallel evals**: `Eval.run/3` runs cases sequentially by default. For speed, wrap in `Task.async_stream/3` manually.
- **Mock LLM in unit tests**: use `config :adk, :llm_backend, ADK.LLM.Mock` in `config/test.exs` to keep evals fast and deterministic.
