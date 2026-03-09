# Writing Evaluations for Your Agent

Evaluations (evals) let you systematically test your agent's quality by running it against predefined test cases and scoring the responses.

## Quick Start

```elixir
alias ADK.Eval
alias ADK.Eval.{Case, Scorer}

# 1. Define your agent
agent = ADK.Agent.LlmAgent.new(
  name: "my_agent",
  model: "gemini-2.0-flash",
  instruction: "You are a helpful assistant."
)

runner = ADK.Runner.new(app_name: "my_app", agent: agent)

# 2. Define test cases
cases = [
  Case.new(
    name: "greeting",
    input: "Hello!",
    scorers: [
      {Scorer.Contains, text: "hello", case_sensitive: false},
      {Scorer.ResponseLength, min: 1, max: 500}
    ]
  ),
  Case.new(
    name: "factual_answer",
    input: "What is 2 + 2?",
    scorers: [
      {Scorer.Contains, text: "4"}
    ]
  )
]

# 3. Run evals
report = Eval.run(runner, cases)
IO.puts(Eval.Report.format(report))
```

## Built-in Scorers

### `ADK.Eval.Scorer.ExactMatch`

Checks if the response exactly matches expected text.

```elixir
{Scorer.ExactMatch, expected: "Hello, world!"}
```

### `ADK.Eval.Scorer.Contains`

Checks if the response contains a substring.

```elixir
{Scorer.Contains, text: "hello", case_sensitive: false}
```

### `ADK.Eval.Scorer.ResponseLength`

Checks if the response length is within bounds.

```elixir
{Scorer.ResponseLength, min: 10, max: 1000}
```

### `ADK.Eval.Scorer.ToolUsed`

Checks if the agent called a specific tool.

```elixir
{Scorer.ToolUsed, name: "search"}
```

## Writing Custom Scorers

Implement the `ADK.Eval.Scorer` behaviour:

```elixir
defmodule MyApp.Scorer.SentimentPositive do
  @behaviour ADK.Eval.Scorer

  @impl true
  def score(events, _opts) do
    text = ADK.Eval.Scorer.response_text(events)

    # Your scoring logic here
    positive_words = ~w(great good wonderful happy)
    found = Enum.any?(positive_words, &String.contains?(String.downcase(text), &1))

    if found do
      %{score: 1.0, pass: true, details: nil}
    else
      %{score: 0.0, pass: false, details: "No positive sentiment detected"}
    end
  end
end
```

## Using in ExUnit Tests

```elixir
defmodule MyApp.AgentEvalTest do
  use ExUnit.Case

  test "agent passes basic eval suite" do
    runner = build_runner()
    cases = build_cases()

    report = ADK.Eval.run(runner, cases, threshold: 0.8)

    assert report.passed == report.total,
           "Failed cases:\n" <> ADK.Eval.Report.format(report)
  end
end
```

## Options

`ADK.Eval.run/3` accepts:

- `:threshold` — minimum aggregate score for a case to pass (default: `1.0`)
- `:user_id` — user ID for sessions (default: `"eval_user"`)

## Helper Functions

- `ADK.Eval.Scorer.response_text(events)` — extract all text from agent response events
- `ADK.Eval.Scorer.function_calls(events)` — extract all function calls from events
