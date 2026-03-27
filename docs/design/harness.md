# ADK Elixir: Harness Design

**Status:** Draft
**Author:** Zaf
**Date:** 2026-03-27
**FR from:** Alan Blount
**Note:** ADK Elixir extension — no Python ADK equivalent exists.

## Problem Statement

A model by itself doesn't do useful work. It needs structure around it:
something to manage context, enforce budgets, validate inputs and outputs,
handle retries, coordinate multi-step workflows, and know when to stop.

Today this structure is ad-hoc. Every agent author reinvents the same
wrapping logic: "run the agent, check the output, retry if bad, stop
after N steps, don't spend more than X tokens." This is the agent
equivalent of writing raw HTTP handlers instead of using a web framework.

**ADK.Harness** is that framework — the thinnest possible wrapper around
agent execution that provides structure without imposing opinions.

Design principle from Alan: **simple interface, layers you can peel back.**

## What We Have Today

| Module | What it does | Gap |
|--------|-------------|-----|
| `ADK.Runner` | Executes agent turns against a session | No budget, no hooks, no validation |
| `ADK.Workflow` | DAG-based multi-step orchestration | Must be manually constructed |
| `ADK.Skill` | Composable agent capabilities (tools + instructions) | No decomposition into workflow nodes |
| `ADK.Agent.LlmAgent` | The core agent struct | No execution wrapper |
| `ADK.LLM.Gateway` | LLM access management | Handles model routing, not agent orchestration |

The Runner does one thing well: execute a turn. But there's nothing that
wraps repeated turns with guardrails, budgets, and feedback loops. That's
what the Harness provides.

## Proposed: ADK.Harness

Three layers of interface. Pick the one that matches your complexity.

### L1 — Simple: Just Run It

Five lines. Works with defaults.

```elixir
agent = ADK.Agent.LlmAgent.new(
  name: "helper",
  model: "gemini-2.5-pro",
  instructions: "You are a helpful assistant."
)

{:ok, result} = ADK.Harness.run(agent, "Summarize this document: #{text}")
IO.puts(result.output)
```

That's it. Behind the scenes, Harness creates a session, runs the agent
with sane defaults (max 10 steps, 5-minute timeout, no token budget),
and returns the final output.

```elixir
defmodule ADK.Harness do
  @moduledoc """
  The simplest way to run an agent. Structure around execution:
  budgets, guardrails, hooks, and feedback loops.

  Progressive disclosure: simple thing is simple, complex thing is possible.
  """

  @type result :: %{
    output: String.t(),
    steps: non_neg_integer(),
    tokens: %{input: non_neg_integer(), output: non_neg_integer()},
    duration_ms: non_neg_integer(),
    status: :ok | :budget_exhausted | :timeout | :guardrail_blocked | :max_steps
  }

  @doc "Run an agent on a task. The simplest possible interface."
  @spec run(ADK.Agent.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(agent, task, opts \\ []) do
    config = Config.from_opts(opts)
    session = opts[:session] || ADK.Session.new()

    with :ok <- run_guardrails(:input, task, config),
         :ok <- check_budget(config) do
      execute_loop(agent, task, session, config)
    end
  end
end
```

### L2 — Configured: Add Budget, Guardrails, Hooks

When defaults aren't enough, pass options:

```elixir
{:ok, result} = ADK.Harness.run(agent, task,
  # Budget constraints
  budget: %{
    max_tokens: 50_000,
    max_steps: 20,
    max_duration_ms: :timer.minutes(10)
  },

  # Guardrails — input/output validation
  guardrails: [
    ADK.Guardrail.ContentFilter.new(block: [:pii, :harmful]),
    ADK.Guardrail.Schema.new(output_schema: %{summary: :string, confidence: :float})
  ],

  # Hooks — observe or modify execution
  hooks: %{
    before_step: fn step, state -> Logger.info("Step #{step}"); state end,
    after_step: fn step, result, state -> state end,
    on_tool_call: fn tool, args -> {tool, args} end
  },

  # Gateway options (passed through to LLM Gateway)
  priority: :background,
  token_budget: %{ref: :summarizer, max_total_tokens: 100_000}
)
```

Guardrails are modules implementing a simple behaviour:

```elixir
defmodule ADK.Guardrail do
  @callback validate(content :: String.t(), config :: map()) ::
    :ok | {:error, reason :: String.t()}
end

defmodule ADK.Guardrail.ContentFilter do
  @behaviour ADK.Guardrail

  def new(opts), do: %__MODULE__{block: opts[:block] || []}

  @impl true
  def validate(content, %{block: categories}) do
    # Check content against blocked categories
    # Uses a lightweight classifier or regex patterns
  end
end

defmodule ADK.Guardrail.Schema do
  @behaviour ADK.Guardrail

  def new(opts), do: %__MODULE__{schema: opts[:output_schema]}

  @impl true
  def validate(content, %{schema: schema}) do
    # Validate structured output matches expected schema
    case Jason.decode(content) do
      {:ok, data} -> validate_shape(data, schema)
      {:error, _} -> {:error, "Output is not valid JSON"}
    end
  end
end
```

### L3 — Advanced: Feedback Loops, DAGs, Multi-Agent

For complex workflows: self-verification, agent-built plans, and
multi-agent composition.

```elixir
{:ok, result} = ADK.Harness.run(agent, task,
  budget: %{max_tokens: 200_000, max_steps: 50},

  # Feedback loop — agent verifies its own output
  feedback: %{
    verifier: verifier_agent,
    max_retries: 3,
    on_reject: fn reason, attempt ->
      "Your previous answer was rejected: #{reason}. Try again (attempt #{attempt}/3)."
    end
  },

  # Multi-agent composition
  agents: %{
    planner: planner_agent,
    executor: executor_agent,
    reviewer: reviewer_agent
  },
  orchestration: :plan_then_execute  # or :debate, :round_robin, :custom
)
```

## Workflow.from_plan/1 — Agent-Built DAGs

Agents can output structured plans that compile to executable workflows:

```elixir
# Agent outputs a plan as structured output
plan = %{
  "steps" => [
    %{"id" => "research", "action" => "search", "query" => "Elixir GenServer patterns"},
    %{"id" => "outline", "action" => "generate", "depends_on" => ["research"],
      "prompt" => "Create an outline based on: {{research.output}}"},
    %{"id" => "draft", "action" => "generate", "depends_on" => ["outline"],
      "prompt" => "Write the full article from: {{outline.output}}"},
    %{"id" => "review", "action" => "review", "depends_on" => ["draft"],
      "prompt" => "Review for accuracy: {{draft.output}}"}
  ]
}

# Compile plan to a DAG workflow
{:ok, workflow} = ADK.Workflow.from_plan(plan)

# Execute through the Harness
{:ok, result} = ADK.Harness.run_workflow(workflow,
  budget: %{max_tokens: 100_000},
  agents: %{default: writer_agent, review: reviewer_agent}
)
```

The plan format is intentionally simple — JSON that an LLM can produce
with basic structured output. `from_plan/1` handles dependency resolution,
template interpolation, and parallel execution of independent steps.

```elixir
defmodule ADK.Workflow do
  # ... existing workflow code ...

  @doc "Compile an agent-generated plan into an executable workflow DAG."
  def from_plan(%{"steps" => steps}) do
    # 1. Parse steps into workflow nodes
    # 2. Resolve depends_on into DAG edges
    # 3. Validate DAG is acyclic
    # 4. Return compiled workflow
    nodes = Enum.map(steps, &plan_step_to_node/1)
    edges = Enum.flat_map(steps, &plan_step_to_edges/1)

    with :ok <- validate_acyclic(nodes, edges) do
      {:ok, %Workflow{nodes: nodes, edges: edges}}
    end
  end
end
```

## Skill-as-DAG

Complex skills can be decomposed into workflow nodes. Instead of a skill
being a monolithic function, it's a mini-DAG:

```elixir
# Today: skill is a single function
defmodule MySkill.Ship do
  use ADK.Skill

  def execute(_args, context) do
    sync(context)     # pull latest
    test(context)     # run tests
    diff(context)     # review changes
    commit(context)   # commit
    push(context)     # push
  end
end

# Proposed: skill as a DAG
defmodule MySkill.Ship do
  use ADK.Skill

  @impl true
  def workflow do
    %{
      "steps" => [
        %{"id" => "sync",   "action" => "shell", "command" => "git pull --rebase"},
        %{"id" => "test",   "action" => "shell", "command" => "mix test",
          "depends_on" => ["sync"]},
        %{"id" => "diff",   "action" => "generate", "depends_on" => ["test"],
          "prompt" => "Review these changes: {{test.output}}"},
        %{"id" => "commit", "action" => "shell", "command" => "git commit -am '{{diff.summary}}'",
          "depends_on" => ["diff"], "requires_approval" => true},
        %{"id" => "push",   "action" => "shell", "command" => "git push",
          "depends_on" => ["commit"]}
      ]
    }
  end
end
```

Benefits:
- Each step has its own error handling and retry logic
- Steps can be individually budgeted
- Independent steps run in parallel automatically
- Approval gates (`requires_approval`) for destructive steps
- Progress tracking via telemetry per step

## Harness Components

### Pre/Post Hooks

```elixir
hooks = %{
  before_run:  fn task, config -> {task, config} end,    # transform task before execution
  after_run:   fn result, config -> result end,           # transform/log final result
  before_step: fn step_num, state -> state end,           # per-step pre-processing
  after_step:  fn step_num, result, state -> state end,   # per-step post-processing
  on_tool_call: fn tool, args -> {tool, args} end,        # intercept tool calls
  on_error:    fn error, state -> {:retry | :abort, state} end
}
```

### Budget

```elixir
budget = %{
  max_tokens: 50_000,           # total input + output tokens
  max_input_tokens: 40_000,     # input tokens only
  max_output_tokens: 10_000,    # output tokens only
  max_steps: 20,                # maximum agent turns
  max_duration_ms: 600_000,     # 10 minute wall clock
  max_cost_usd: 1.00            # estimated USD spend cap
}
```

On exhaustion, the Harness returns `{:ok, %{status: :budget_exhausted, ...}}`
with whatever partial output exists — it doesn't crash or raise.

### Guardrails

Input and output validation, run before first step and after final output:

| Guardrail | Phase | What it does |
|-----------|-------|-------------|
| `ContentFilter` | Input + Output | Block PII, harmful content, prompt injection |
| `Schema` | Output | Validate structured output shape |
| `Length` | Output | Enforce min/max output length |
| `Custom` | Any | User-defined validation function |

### Feedback Loops

Self-verification: the agent checks its own work.

```elixir
feedback = %{
  verifier: verifier_agent,     # separate agent that reviews output
  max_retries: 3,               # max verification attempts
  on_reject: fn reason, attempt ->
    # Generate retry prompt with feedback
    "Previous attempt rejected: #{reason}. Please revise."
  end,
  on_accept: fn result -> result end
}
```

The loop: execute → verify → if rejected, re-execute with feedback → verify again.
Verification attempts count against the step and token budgets.

## Telemetry Events

```
[:adk, :harness, :run, :start]       — harness execution started
[:adk, :harness, :run, :stop]        — harness execution completed
[:adk, :harness, :step, :start]      — individual step started
[:adk, :harness, :step, :stop]       — individual step completed
[:adk, :harness, :guardrail, :check] — guardrail validation run
[:adk, :harness, :guardrail, :block] — guardrail blocked content
[:adk, :harness, :budget, :warning]  — budget > 80% consumed
[:adk, :harness, :budget, :exhausted] — budget exhausted, execution stopped
[:adk, :harness, :feedback, :reject] — verifier rejected output
[:adk, :harness, :feedback, :accept] — verifier accepted output
```

## gitagent Compatibility

The [gitagent spec](https://github.com/open-gitagent/gitagent) defines
conventions for agent-friendly repos. ADK Elixir aligns where it makes
sense and differs where Elixir patterns are stronger.

| gitagent Convention | ADK Elixir Equivalent | Status |
|--------------------|-----------------------|--------|
| `SOUL.md` | Agent `instructions` field | ✅ Compatible — can load from SOUL.md |
| `skills/` directory | `ADK.Skill` modules | ✅ Compatible — skills/ maps to Skill modules |
| `memory/` directory | `ADK.Session` + memory tools | ⚠️ Different — we use structured sessions, not flat files |
| `.gitagent.yml` config | `config :adk` application env | ⚠️ Different — Elixir config conventions |
| Tool declarations | `ADK.Tool` / `ADK.Skill.tools/0` | ✅ Compatible — same concept |

The Harness can load gitagent-style repos:

```elixir
# Load agent config from a gitagent-compatible repo
{:ok, agent} = ADK.Harness.from_repo("/path/to/repo")
# Reads SOUL.md → instructions, skills/ → Skill modules, .gitagent.yml → config
```

## Module Structure

```
lib/adk/
  harness.ex              # Main entry point — run/2, run/3
  harness/
    config.ex             # Option parsing, defaults, validation
    budget.ex             # Token/step/time/cost budget tracking
    guardrail.ex          # Guardrail behaviour + built-in guardrails
    feedback.ex           # Feedback loop (verify → retry)
    hooks.ex              # Hook management and execution
  workflow.ex             # Existing — add from_plan/1
  skill.ex                # Existing — add workflow/0 callback
```

## Unresolved Design Questions

### UQ1: Harness as process or function?

Option A: `Harness.run/3` is a plain function that blocks until done.
- Pro: Simplest mental model. Easy to test.
- Con: No way to inspect mid-execution, cancel, or stream progress.

Option B: `Harness.start/3` returns a process; results via message or await.
- Pro: Cancellation, progress streaming, inspection.
- Con: More complex API surface.

**Leaning:** A for L1/L2, B available for L3. `run/3` blocks, `start/3` returns
a process handle for advanced use.

### UQ2: Guardrail ordering

Should guardrails run in declared order (pipeline) or concurrently? If one
guardrail is slow (e.g., calls an external classifier), it blocks all others
in pipeline mode.

**Leaning:** Pipeline (sequential) by default, with `concurrent: true` opt-in.

### UQ3: Budget sharing across multi-agent — RESOLVED

**Decision:** Shared budget. The Harness owns the budget, all agents within
draw from it. Per-agent sub-budgets available as opt-in for advanced use.

### UQ4: Skill workflow discovery — RESOLVED

**Decision:** Proactive dagification. The Harness automatically decomposes any
skill that declares steps into a DAG. No opt-in behaviour needed.

Skills declare steps as an ordered list of operations. The Harness analyzes
dependencies between steps, finds independent ones that can run in parallel,
and inserts checkpoints between nodes. A skill author writes sequential logic;
the Harness finds the concurrency.

```elixir
# Skill author writes this:
defmodule MyApp.Skills.Ship do
  use ADK.Skill

  steps do
    step :sync,    fn ctx -> Git.pull(ctx.repo) end
    step :test,    fn ctx -> Mix.test(ctx.repo) end,    depends_on: [:sync]
    step :lint,    fn ctx -> Mix.lint(ctx.repo) end,    depends_on: [:sync]
    step :review,  fn ctx -> Review.diff(ctx.repo) end, depends_on: [:test, :lint]
    step :commit,  fn ctx -> Git.commit(ctx.repo) end,  depends_on: [:review]
    step :push,    fn ctx -> Git.push(ctx.repo) end,    depends_on: [:commit]
  end
end

# Harness sees: test + lint are independent → parallel after sync
# Automatic checkpoints between each node for resume on failure
```

If a skill has no `steps` block, it's called via `execute/2` as today (single node).

### UQ5: Plan format standardization

Should `Workflow.from_plan/1` accept only our format, or also support
external plan formats (e.g., OpenAI function calling chains, LangGraph
state machines)?

**Leaning:** Our format only for v1. Adapters for external formats as needed.

## References

- [OpenAI — Harness Engineering](https://openai.com/index/harness-engineering/) — OpenAI's approach to structuring agent execution
- [LangChain — The Anatomy of an Agent Harness](https://blog.langchain.com/the-anatomy-of-an-agent-harness/) — LangChain's harness patterns
- [gitagent spec](https://github.com/open-gitagent/gitagent) — Open standard for agent-friendly repositories
- Alan Blount — "ADK Skill Design Patterns" (LinkedIn post) — progressive disclosure in skill interfaces
- [ADK Elixir — LLM Gateway Design](./llm-gateway.md) — Gateway.Scheduler for priority/budget integration
- [ADK Elixir — Skill Auth Design](./skill-auth.md) — credential flow through tools and skills
