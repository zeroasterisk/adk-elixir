# Agent Design Patterns

Practical patterns for building agents with ADK Elixir. Each pattern includes
copy-paste Elixir code and links to working examples in this repo.

> **Prerequisite**: Read the [Getting Started](getting-started.md) and
> [Concepts](concepts.md) guides first. This guide assumes you know how to
> create agents and run them.

---

## Pattern Index

| # | Pattern | Complexity | Example |
|---|---------|-----------|---------|
| 1 | [Single Agent + Tools](#single-agent-with-tools) | ⭐ | `examples/tool_use/` |
| 2 | [Coordinator / Dispatcher](#coordinator--dispatcher) | ⭐⭐ | `examples/multi_agent/` |
| 3 | [Sequential Pipeline](#sequential-pipeline) | ⭐⭐ | `examples/sequential_agent/` |
| 4 | [Parallel Fan-Out / Gather](#parallel-fan-out--gather) | ⭐⭐ | — |
| 5 | [Iterative Refinement (Loop)](#iterative-refinement-loop) | ⭐⭐ | — |
| 6 | [Review / Critique (Generator-Critic)](#review--critique-generator-critic) | ⭐⭐ | `examples/reflect_retry/` |
| 7 | [Hierarchical Task Decomposition](#hierarchical-task-decomposition) | ⭐⭐⭐ | `examples/claw/` |
| 8 | [Custom Agent (Arbitrary Logic)](#custom-agent-arbitrary-logic) | ⭐⭐⭐ | — |
| 9 | [Guardrails & Policy Enforcement](#guardrails--policy-enforcement) | ⭐⭐ | `examples/claw/` |
| 10 | [Human-in-the-Loop (HITL)](#human-in-the-loop) | ⭐⭐ | `examples/claw/` |
| 11 | [Callbacks: Logging, Caching, Modification](#callbacks) | ⭐⭐ | `examples/claw/` |
| 12 | [Long-Running Tools](#long-running-tools) | ⭐⭐ | `examples/claw/` |
| 13 | [Memory & Cross-Session Recall](#memory--cross-session-recall) | ⭐⭐ | `examples/rag_agent/` |
| 14 | [Artifacts](#artifacts) | ⭐ | `examples/claw/` |
| 15 | [Authentication & Credentials](#authentication--credentials) | ⭐⭐ | `examples/claw/` |
| 16 | [Agent-to-Agent (A2A)](#agent-to-agent-a2a) | ⭐⭐⭐ | `examples/claw/` |
| 17 | [Skills (Reusable Instruction Bundles)](#skills) | ⭐ | — |
| 18 | [Context Compaction](#context-compaction) | ⭐⭐ | `examples/context_compilation/` |
| 19 | [Eval & Testing](#eval--testing) | ⭐⭐ | `examples/claw/` |
| 20 | [Plugins (Global Middleware)](#plugins-global-middleware) | ⭐⭐ | — |
| 21 | [MCP Tool Integration](#mcp-tool-integration) | ⭐⭐ | — |
| 22 | [Structured Output (output_schema)](#structured-output) | ⭐ | — |
| 23 | [Dynamic Instructions](#dynamic-instructions) | ⭐ | — |
| 24 | [Oban Background Jobs](#oban-background-jobs) | ⭐⭐ | — |
| 25 | [Phoenix LiveView Integration](#phoenix-liveview-integration) | ⭐⭐ | — |

---

## Single Agent with Tools

The simplest useful pattern: one LLM agent equipped with function tools.

**When to use**: Most single-purpose agents. Start here.

```elixir
# Define tools as functions
get_weather = ADK.Tool.FunctionTool.new(:get_weather,
  description: "Get current weather for a city",
  func: fn _ctx, %{"city" => city} ->
    {:ok, "#{city}: 22°C, sunny"}
  end,
  parameters: %{
    type: "object",
    properties: %{city: %{type: "string", description: "City name"}},
    required: ["city"]
  }
)

# Or use MFA tuples for compile-time safety
calculate = ADK.Tool.FunctionTool.new(:calculate,
  description: "Evaluate a math expression",
  func: {MyApp.Tools, :calculate},
  parameters: %{
    type: "object",
    properties: %{expression: %{type: "string"}},
    required: ["expression"]
  }
)

# Wire tools into an agent
agent = ADK.Agent.LlmAgent.new(
  name: "assistant",
  model: "gemini-flash-latest",
  instruction: """
  You are a helpful assistant. Use tools when needed.
  - Use get_weather for weather questions
  - Use calculate for math
  """,
  tools: [get_weather, calculate]
)

# Run it
runner = %ADK.Runner{app_name: "my_app", agent: agent}
events = ADK.Runner.run(runner, "user1", "s1", "What's the weather in Tokyo?")
```

**Key points**:
- Tools are `ADK.Tool.FunctionTool` structs (or any `ADK.Tool` behaviour impl)
- `func` accepts anonymous functions or `{Module, :function}` / `{Module, :function, extra_args}` MFA tuples
- The LLM decides when and which tools to call based on your instruction + tool descriptions
- Tool functions receive `(tool_ctx, args)` — use `tool_ctx` for state, artifacts, credentials

📁 **See**: [`examples/tool_use/`](../examples/tool_use/)

---

## Coordinator / Dispatcher

A central agent routes incoming requests to specialist sub-agents via LLM-driven transfer.

**When to use**: When you have distinct domains (billing, support, search) and want the LLM to decide routing dynamically.

```elixir
weather_agent = ADK.Agent.LlmAgent.new(
  name: "weather_agent",
  model: "gemini-flash-latest",
  description: "Handles weather queries",
  instruction: "You answer weather questions. Use the get_weather tool.",
  tools: [get_weather_tool()]
)

math_agent = ADK.Agent.LlmAgent.new(
  name: "math_agent",
  model: "gemini-flash-latest",
  description: "Handles math calculations",
  instruction: "You solve math problems. Use the calculate tool.",
  tools: [calculate_tool()]
)

router = ADK.Agent.LlmAgent.new(
  name: "router",
  model: "gemini-flash-latest",
  instruction: """
  You are a router. Analyze the user's question and transfer to the
  appropriate specialist agent. Don't try to answer directly.
  """,
  sub_agents: [weather_agent, math_agent]
)
```

**How transfer works**:
1. ADK auto-generates `transfer_to_agent_weather_agent` and `transfer_to_agent_math_agent` tools
2. The router's LLM picks the right tool based on the user's query
3. The runner detects the transfer event and delegates to the target agent
4. The sub-agent runs and its response is returned

**Elixir difference**: Python creates one `transfer_to_agent` tool with an enum
parameter. Elixir creates one tool *per* sub-agent — the LLM picks the tool by
name, eliminating parameter hallucination.

📁 **See**: [`examples/multi_agent/`](../examples/multi_agent/)

---

## Sequential Pipeline

A `SequentialAgent` runs sub-agents in order. Each step's output is available to the next via shared session state.

**When to use**: Multi-step workflows (research → write → edit), data pipelines, ETL-style processing.

```elixir
researcher = ADK.Agent.LlmAgent.new(
  name: "researcher",
  model: "gemini-flash-latest",
  instruction: "Research the given topic. Output 5-7 bullet points.",
  output_key: "research"  # Saves output to state["research"]
)

writer = ADK.Agent.LlmAgent.new(
  name: "writer",
  model: "gemini-flash-latest",
  instruction: """
  Write a blog post based on this research:
  {research}
  """,
  output_key: "draft"
)

editor = ADK.Agent.LlmAgent.new(
  name: "editor",
  model: "gemini-flash-latest",
  instruction: """
  Edit this draft for clarity and tone:
  {draft}
  """
)

pipeline = ADK.Agent.SequentialAgent.new(
  name: "content_pipeline",
  description: "Research → Write → Edit",
  sub_agents: [researcher, writer, editor]
)
```

**Key points**:
- `output_key` saves the agent's final text to session state under that key
- `{variable}` in instructions is replaced with the matching state value
- All sub-agents share the same session state — data flows through state keys
- Append `?` to optional variables: `{maybe_context?}` won't error if missing

📁 **See**: [`examples/sequential_agent/`](../examples/sequential_agent/)

---

## Parallel Fan-Out / Gather

A `ParallelAgent` runs sub-agents concurrently, then a downstream agent aggregates results.

**When to use**: Independent tasks that can run simultaneously (fetching from multiple APIs, running different analyses).

```elixir
fetch_weather = ADK.Agent.LlmAgent.new(
  name: "weather_fetcher",
  model: "gemini-flash-latest",
  instruction: "Get the weather for {city}.",
  output_key: "weather_data",
  tools: [weather_tool()]
)

fetch_news = ADK.Agent.LlmAgent.new(
  name: "news_fetcher",
  model: "gemini-flash-latest",
  instruction: "Find today's top news for {city}.",
  output_key: "news_data",
  tools: [news_tool()]
)

# Fan-out: run both concurrently
gatherer = ADK.Agent.ParallelAgent.new(
  name: "info_gatherer",
  sub_agents: [fetch_weather, fetch_news]
)

# Gather: combine results
summarizer = ADK.Agent.LlmAgent.new(
  name: "summarizer",
  model: "gemini-flash-latest",
  instruction: """
  Combine these into a morning briefing:
  Weather: {weather_data}
  News: {news_data}
  """
)

# Full pipeline: fan-out then gather
briefing = ADK.Agent.SequentialAgent.new(
  name: "morning_briefing",
  sub_agents: [gatherer, summarizer]
)
```

**Key points**:
- `ParallelAgent` uses `Task.async_stream` under the hood — real BEAM concurrency
- All parallel children share the same session state — use distinct `output_key`s to avoid races
- Each parallel child gets a branch prefix in its context (e.g., `"info_gatherer.weather_fetcher"`)
- Commonly nested inside a `SequentialAgent` for the gather step

---

## Iterative Refinement (Loop)

A `LoopAgent` runs its sub-agents repeatedly until a condition is met or max iterations reached.

**When to use**: Progressive improvement, polling, retry-until-success.

```elixir
improver = ADK.Agent.LlmAgent.new(
  name: "improver",
  model: "gemini-flash-latest",
  instruction: """
  Improve this code based on the feedback:
  Code: {code}
  Feedback: {feedback?}

  Output ONLY the improved code.
  """,
  output_key: "code"
)

reviewer = ADK.Agent.LlmAgent.new(
  name: "reviewer",
  model: "gemini-flash-latest",
  instruction: """
  Review this code: {code}

  If it's production-ready, respond with ONLY the word "APPROVED".
  Otherwise, provide specific feedback for improvement.
  """,
  output_key: "feedback"
)

# Check if the reviewer approved
checker = ADK.Agent.Custom.new(
  name: "checker",
  run_fn: fn _agent, ctx ->
    feedback = ADK.Context.get_state(ctx, "feedback") || ""
    approved = String.contains?(feedback, "APPROVED")
    [ADK.Event.new(%{author: "checker", actions: %{escalate: approved}})]
  end
)

refinement_loop = ADK.Agent.LoopAgent.new(
  name: "code_refiner",
  max_iterations: 5,
  sub_agents: [improver, reviewer, checker]
)
```

**Key points**:
- The loop stops when any sub-agent emits an event with `actions.escalate: true`
- Or when `max_iterations` is reached
- State persists across iterations — use it for counters, flags, accumulated data
- You can also use `ADK.Tool.ExitLoop` as a tool the LLM can call to break out

---

## Review / Critique (Generator-Critic)

One agent generates, another validates. If validation fails, the generator retries with feedback.

**When to use**: Enforcing output format (JSON, specific schema), quality gates, factual accuracy.

```elixir
agent = ADK.Agent.LlmAgent.new(
  name: "json_responder",
  model: "gemini-flash-latest",
  instruction: "Respond with valid JSON only. No markdown, no explanation.",
  plugins: [
    {ADK.Plugin.ReflectRetry,
     max_retries: 3,
     validator: fn events ->
       text =
         events
         |> Enum.map(&(ADK.Event.text(&1) || ""))
         |> Enum.join("")
         |> String.trim()

       case Jason.decode(text) do
         {:ok, _} -> :ok
         {:error, _} ->
           {:error, "Invalid JSON. Output ONLY a JSON object, no markdown fences."}
       end
     end}
  ]
)
```

**How `ReflectRetry` works**:
1. Agent generates a response
2. Your `validator` function checks it
3. If `:ok`, the response passes through
4. If `{:error, feedback}`, the feedback is appended to the conversation and the agent retries
5. After `max_retries`, the last response is returned regardless

📁 **See**: [`examples/reflect_retry/`](../examples/reflect_retry/)

---

## Hierarchical Task Decomposition

Multi-level agent trees where higher-level agents break down tasks and delegate to specialists.

**When to use**: Complex domains with sub-domains (e.g., a coding assistant with file/shell/test sub-agents).

```elixir
# Level 2: Specialists
coder = ADK.Agent.LlmAgent.new(
  name: "coder",
  model: "gemini-flash-latest",
  description: "Writes and explains code",
  instruction: "You write clean, idiomatic code. Explain your approach.",
  tools: [shell_tool(), read_file_tool()]
)

helper = ADK.Agent.LlmAgent.new(
  name: "helper",
  model: "gemini-flash-latest",
  description: "General knowledge and utilities",
  instruction: "You help with general questions, datetime, notes.",
  tools: [datetime_tool(), save_note_tool(), list_notes_tool()]
)

# Level 1: Router
router = ADK.Agent.LlmAgent.new(
  name: "claw",
  model: "gemini-flash-latest",
  instruction: """
  You are Claw, an AI assistant. Route requests to the right specialist:
  - Code/programming questions → transfer to coder
  - Everything else → transfer to helper

  If you can answer directly without a specialist, do so.
  """,
  sub_agents: [coder, helper]
)
```

**Key points**:
- Sub-agents can themselves have sub-agents (arbitrary depth)
- Transfer targets respect the `disallow_transfer_to_parent` and `disallow_transfer_to_peers` flags
- Each agent in the hierarchy gets its own instruction context
- Use `description` liberally — it's what the parent LLM uses to decide routing

📁 **See**: [`examples/claw/`](../examples/claw/)

---

## Custom Agent (Arbitrary Logic)

When workflow agents don't fit, implement `ADK.Agent` protocol directly.

**When to use**: Conditional routing, external API calls in the orchestration layer, dynamic agent selection, anything non-standard.

```elixir
# Quick: use ADK.Agent.Custom for simple cases
conditional_agent = ADK.Agent.Custom.new(
  name: "conditional_router",
  run_fn: fn _agent, ctx ->
    user_tier = ADK.Context.get_state(ctx, "user_tier") || "free"

    sub = case user_tier do
      "premium" -> premium_agent()
      _ -> free_agent()
    end

    ADK.Agent.run(sub, ctx)
  end
)

# Full: implement the protocol on your own struct
defmodule MyAgent do
  defstruct [:name, :sub_agents, description: ""]

  defimpl ADK.Agent do
    def name(agent), do: agent.name
    def description(agent), do: agent.description
    def sub_agents(agent), do: agent.sub_agents

    def run(agent, ctx) do
      # Run first sub-agent
      events_a = ADK.Agent.run(hd(agent.sub_agents), ctx)

      # Inspect result, decide next step
      has_error = Enum.any?(events_a, &(&1.actions[:error]))

      if has_error do
        # Fallback path
        ADK.Agent.run(List.last(agent.sub_agents), ctx)
      else
        events_a
      end
    end
  end
end
```

**Key points**:
- `ADK.Agent` is a protocol, not a class — implement it on any struct
- `ADK.Agent.Custom` is a convenience for closures / quick prototypes
- You control the full execution flow: conditionals, retries, external calls
- Yield events from sub-agents for proper event tracking

---

## Guardrails & Policy Enforcement

Use `ADK.Policy` to enforce rules before tools execute, and to filter input/output.

**When to use**: Restricting dangerous operations, content filtering, PII redaction, rate limiting.

```elixir
defmodule SafetyPolicy do
  @behaviour ADK.Policy

  # Block dangerous tools
  @impl true
  def authorize_tool(%{name: "shell_command"}, %{"command" => cmd}, _ctx) do
    if String.contains?(cmd, ["rm -rf", "sudo", "curl"]) do
      {:deny, "That command is not allowed for safety reasons."}
    else
      :allow
    end
  end
  def authorize_tool(_tool, _args, _ctx), do: :allow

  # Filter PII from input
  @impl true
  def filter_input(content, _ctx) do
    cleaned = String.replace(content, ~r/\b\d{3}-\d{2}-\d{4}\b/, "[SSN REDACTED]")
    {:cont, cleaned}
  end

  # Pass output through unchanged
  @impl true
  def filter_output(events, _ctx), do: events
end

# Apply to runner
ADK.Runner.run(runner, user_id, session_id, message,
  policies: [SafetyPolicy]
)
```

**Composition**: Multiple policies chain as responsibility:
- `authorize_tool` — first `:deny` wins; all must `:allow`
- `filter_input` — chained sequentially; `{:halt, events}` short-circuits
- `filter_output` — chained sequentially, each transforms the event list

**Elixir-only**: Python ADK uses ad-hoc callbacks for this. ADK Elixir has a
dedicated `ADK.Policy` behaviour — cleaner separation of concerns.

---

## Human-in-the-Loop

Require human approval before executing sensitive tools.

**When to use**: Destructive operations, financial transactions, sending emails, anything with real-world consequences.

```elixir
# Built-in confirmation policy
policy = ADK.Policy.HumanApproval.new(
  # Tools that require approval
  tools: ["delete_file", "send_email", "execute_payment"],
  # Function that asks the human and returns :approved or {:denied, reason}
  confirm_fn: fn tool_name, args, _ctx ->
    IO.puts("Agent wants to call #{tool_name} with #{inspect(args)}")
    response = IO.gets("Approve? (y/n): ") |> String.trim()
    if response == "y", do: :approved, else: {:denied, "User declined"}
  end
)

ADK.Runner.run(runner, user_id, session_id, message,
  policies: [policy]
)
```

**In Phoenix LiveView**, the confirm function can push an approval dialog to the browser
and await the user's click — see the [Phoenix Integration](phoenix-integration.md) guide.

**Python comparison**: Python ADK documents HITL as a pattern; ADK Elixir provides
`ADK.Policy.HumanApproval` as a first-class API.

📁 **See**: [`examples/claw/`](../examples/claw/) (uses `delete_file` with HITL)

---

## Callbacks

Hook into the agent lifecycle for logging, caching, request/response modification.

**When to use**: Observability, debugging, request enrichment, response transformation.

```elixir
defmodule LoggingCallbacks do
  @behaviour ADK.Callback

  @impl true
  def before_agent(callback_ctx) do
    IO.puts("[#{callback_ctx.agent.name}] Starting...")
    {:cont, callback_ctx}
  end

  @impl true
  def after_agent(events, callback_ctx) do
    IO.puts("[#{callback_ctx.agent.name}] Produced #{length(events)} events")
    events
  end

  @impl true
  def before_model(callback_ctx) do
    IO.puts("[LLM] Calling model...")
    {:cont, callback_ctx}
  end

  @impl true
  def after_model(response, _callback_ctx), do: response

  @impl true
  def before_tool(callback_ctx) do
    IO.puts("[Tool] #{callback_ctx.tool.name} called with #{inspect(callback_ctx.tool_args)}")
    {:cont, callback_ctx}
  end

  @impl true
  def after_tool(result, _callback_ctx), do: result
end

# Caching pattern: short-circuit with before_model
defmodule CachingCallbacks do
  @behaviour ADK.Callback

  # ... other callbacks return {:cont, ctx} ...

  @impl true
  def before_model(callback_ctx) do
    cache_key = :erlang.phash2(callback_ctx.request)
    case :persistent_term.get({:llm_cache, cache_key}, nil) do
      nil -> {:cont, callback_ctx}
      cached -> {:halt, {:ok, cached}}  # Skip LLM call
    end
  end

  @impl true
  def after_model(response, callback_ctx) do
    cache_key = :erlang.phash2(callback_ctx.request)
    :persistent_term.put({:llm_cache, cache_key}, response)
    response
  end
end

ADK.Runner.run(runner, user_id, session_id, message,
  callbacks: [LoggingCallbacks, CachingCallbacks]
)
```

**Callback types**:
| Hook | Short-circuit with | Use case |
|------|--------------------|----------|
| `before_agent` | `{:halt, events}` | Skip agent, return canned response |
| `before_model` | `{:halt, {:ok, response}}` | Cache, rate limit |
| `before_tool` | `{:halt, result}` | Mock tools, circuit break |
| `after_*` | Transform result | Logging, enrichment, filtering |

---

## Long-Running Tools

Tools that take time (API calls, file processing) run in supervised OTP tasks with progress updates.

**When to use**: Any tool that might take more than a few seconds.

```elixir
research_tool = ADK.Tool.LongRunningTool.new(:research,
  description: "Research a topic in depth (may take a while)",
  func: fn _ctx, %{"topic" => topic}, send_update ->
    send_update.("Searching for #{topic}...")
    Process.sleep(2_000)  # Simulate slow work

    send_update.("Found 5 sources, analyzing...")
    Process.sleep(3_000)

    {:ok, "Research complete: #{topic} is fascinating because..."}
  end,
  parameters: %{
    type: "object",
    properties: %{topic: %{type: "string"}},
    required: ["topic"]
  },
  timeout: 30_000  # 30 second timeout
)
```

**How it works**:
1. Tool spawns a supervised `Task` under `ADK.RunnerSupervisor`
2. The `send_update` callback emits intermediate status messages
3. If the task crashes, the supervisor catches it — no cascading failure
4. Timeout is enforced via `receive...after`

**Python comparison**: Python uses `is_long_running = True` + async/await. Elixir uses
OTP processes — crash isolation and supervision come free.

📁 **See**: [`examples/claw/`](../examples/claw/) (`research` tool)

---

## Memory & Cross-Session Recall

Let agents remember information across conversations.

**When to use**: Persistent assistants, learning from past interactions, knowledge bases.

```elixir
# Configure runner with a memory store
runner = ADK.Runner.new(
  app_name: "my_app",
  agent: agent,
  memory_store: {ADK.Memory.InMemory, name: ADK.Memory.InMemory}
)

# Give the agent a memory search tool
agent = ADK.Agent.LlmAgent.new(
  name: "assistant",
  model: "gemini-flash-latest",
  instruction: """
  You are a helpful assistant with memory of past conversations.
  Use search_memory when the user asks about something from a previous chat.
  """,
  tools: [ADK.Tool.SearchMemoryTool]
)
```

**Memory stores available**:
- `ADK.Memory.InMemory` — keyword search, good for prototyping
- Vertex AI Memory Bank — semantic search, production-grade (see [intentional differences](../docs/intentional-differences.md))

**Flow**:
1. After a session ends, call `memory_store.add_session/1` to ingest it
2. When the agent uses `search_memory`, it queries the store
3. Results are returned as tool output for the LLM to incorporate

📁 **See**: [`examples/rag_agent/`](../examples/rag_agent/) (in-memory RAG),
[`examples/claw/`](../examples/claw/) (memory integration)

---

## Artifacts

Save and load binary data (files, images, reports) associated with a session.

**When to use**: File generation, image storage, report caching.

```elixir
save_note = ADK.Tool.FunctionTool.new(:save_note,
  description: "Save a named note",
  func: fn ctx, %{"name" => name, "content" => content} ->
    ADK.ToolContext.save_artifact(ctx, name, content)
    {:ok, "Saved note '#{name}'"}
  end,
  parameters: %{
    type: "object",
    properties: %{
      name: %{type: "string", description: "Note name"},
      content: %{type: "string", description: "Note content"}
    },
    required: ["name", "content"]
  }
)

list_notes = ADK.Tool.FunctionTool.new(:list_notes,
  description: "List all saved notes",
  func: fn ctx, _args ->
    notes = ADK.ToolContext.list_artifacts(ctx)
    {:ok, Enum.join(notes, ", ")}
  end,
  parameters: %{type: "object", properties: %{}}
)
```

**Artifact stores**:
- `ADK.Artifact.InMemory` — started by `ADK.Application`, good for dev
- `ADK.Artifact.GCS` — Google Cloud Storage, for production

📁 **See**: [`examples/claw/`](../examples/claw/)

---

## Authentication & Credentials

Manage OAuth2 and API key credentials for tools that access protected resources.

**When to use**: Calling external APIs that require auth (Google Calendar, Salesforce, etc.).

```elixir
call_api = ADK.Tool.FunctionTool.new(:call_api,
  description: "Call an external API",
  func: fn ctx, %{"endpoint" => endpoint} ->
    case ADK.ToolContext.get_credential(ctx, "api_token") do
      nil ->
        # Request credentials — triggers auth flow
        {:error, {:auth_required, %{
          scheme: :oauth2,
          scopes: ["read", "write"],
          auth_url: "https://example.com/oauth/authorize"
        }}}

      token ->
        # Use the credential
        {:ok, "Called #{endpoint} with token #{String.slice(token, 0..5)}..."}
    end
  end,
  parameters: %{
    type: "object",
    properties: %{endpoint: %{type: "string"}},
    required: ["endpoint"]
  }
)
```

**Elixir difference**: Python uses an `AuthRequestProcessor` in its 12-step pipeline.
Elixir handles auth inline with `{:error, {:auth_required, config}}` return values — simpler control flow.

📁 **See**: [`examples/claw/`](../examples/claw/) (`call_mock_api` tool)

---

## Agent-to-Agent (A2A)

Expose your agent as an A2A endpoint, or call remote agents as tools.

**When to use**: Microservice-style agent architectures, cross-team agent collaboration.

### Exposing an Agent

```elixir
# In your Phoenix router
scope "/a2a", MyAppWeb do
  post "/", A2AController, :handle
  get "/.well-known/agent.json", A2AController, :agent_card
end

# Controller
defmodule MyAppWeb.A2AController do
  use MyAppWeb, :controller

  def agent_card(conn, _params) do
    card = ADK.A2A.AgentCard.new(
      name: "my-agent",
      description: "A helpful assistant",
      url: "https://my-agent.example.com/a2a"
    )
    json(conn, card)
  end

  def handle(conn, params) do
    response = ADK.A2A.Server.handle_request(params, runner())
    json(conn, response)
  end
end
```

### Calling a Remote Agent

```elixir
remote_tool = ADK.A2A.RemoteAgentTool.new(
  name: "expert_agent",
  description: "Call the expert agent for specialized questions",
  url: "https://expert-agent.example.com/a2a"
)

agent = ADK.Agent.LlmAgent.new(
  name: "coordinator",
  model: "gemini-flash-latest",
  instruction: "Use expert_agent for specialized questions.",
  tools: [remote_tool]
)
```

**Elixir difference**: Python ADK has A2A as a separate package. ADK Elixir bundles
`ADK.A2A` as a first-class module.

📁 **See**: [`examples/claw/`](../examples/claw/) (A2A controller)

---

## Skills

Bundle reusable instructions (and optionally tools) into a skill directory.

**When to use**: Sharing agent capabilities across projects, creating an instruction library.

```elixir
# Load a skill from a directory
{:ok, skill} = ADK.Skill.from_dir("path/to/skills/code_review")

# Use it with an agent — skill instructions are appended
agent = ADK.Agent.LlmAgent.new(
  name: "reviewer",
  model: "gemini-flash-latest",
  instruction: "You are a code reviewer.",
  skills: [skill]
)
```

**Skill directory structure**:
```
skills/code_review/
├── SKILL.md          # Required — instructions, name from # heading
├── tools.ex          # Optional — additional tools
└── references/       # Optional — reference docs
```

Skills are composable — an agent can load multiple skills, each adding instructions and tools.

---

## Context Compaction

Manage growing conversation context to keep LLM calls fast and within token limits.

**When to use**: Long conversations, cost optimization, avoiding context window limits.

```elixir
# Choose a compaction strategy
agent = ADK.Agent.LlmAgent.new(
  name: "assistant",
  model: "gemini-flash-latest",
  instruction: "You are a helpful assistant.",
  context_compressor: [
    strategy: ADK.Context.Compressor.TokenBudget,
    token_budget: 8_000,    # Max tokens to keep
    keep_recent: 3,          # Always keep last 3 messages
    keep_system: true        # Always keep system instructions
  ]
)
```

**Available strategies**:
| Strategy | Description |
|----------|-------------|
| `SlidingWindow` | Keep the last N messages |
| `Summarize` | Summarize older messages using an LLM |
| `Truncate` | Hard-cut at a character/token limit |
| `TokenBudget` | Token-aware budget with greedy fill |

**Elixir-only**: Python ADK has token-budget compaction only. ADK Elixir provides
four strategies out of the box.

📁 **See**: [`examples/context_compilation/`](../examples/context_compilation/),
[Context Compilation guide](context-compilation.md)

---

## Eval & Testing

Evaluate agent quality with structured test scenarios and scorers.

**When to use**: CI/CD quality gates, regression testing, comparing prompt strategies.

```elixir
defmodule MyAgentEvalTest do
  use ADK.Eval.Case

  setup do
    {:ok, agent: my_agent(), runner: my_runner()}
  end

  eval "answers capital city questions",
    input: "What is the capital of France?",
    expected: "Paris",
    scorers: [
      {ADK.Eval.Scorer.Contains, substring: "Paris"},
      {ADK.Eval.Scorer.ResponseLength, min: 10, max: 200}
    ]

  eval "uses weather tool for weather queries",
    input: "What's the weather in Tokyo?",
    scorers: [
      {ADK.Eval.Scorer.ToolUsed, tool: "get_weather"}
    ]
end
```

**Built-in scorers**:
- `Contains` — checks if response contains a substring
- `ExactMatch` — exact string match
- `ResponseLength` — min/max length bounds
- `ToolUsed` — verifies a specific tool was called

📁 **See**: [`examples/claw/test/claw_eval_test.exs`](../examples/claw/test/claw_eval_test.exs),
[Evaluations guide](evaluations.md)

---

## Plugins (Global Middleware)

Plugins are **runner-level** middleware that apply globally to all agents. Unlike
callbacks (per-agent), plugins intercept the entire Runner pipeline plus
per-model and per-tool hooks for every agent in the hierarchy.

**When to use**: Cross-cutting concerns — logging, rate limiting, caching, metrics,
security enforcement across all agents.

```elixir
defmodule MetricsPlugin do
  @behaviour ADK.Plugin

  @impl true
  def init(_config) do
    :ets.new(:adk_metrics, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @impl true
  def before_run(context, state) do
    :ets.update_counter(:adk_metrics, :total_runs, 1, {:total_runs, 0})
    {:cont, context, state}
  end

  @impl true
  def after_run(result, _context, state), do: {result, state}

  # Intercept every LLM call across all agents
  @impl true
  def before_model(_context, request) do
    :ets.update_counter(:adk_metrics, :llm_calls, 1, {:llm_calls, 0})
    {:ok, request}
  end

  @impl true
  def after_model(_context, response), do: response

  # Intercept every tool call
  @impl true
  def before_tool(_context, _tool, args), do: {:ok, args}

  @impl true
  def after_tool(_context, _tool, result), do: result

  @impl true
  def on_event(_context, event) do
    :ets.update_counter(:adk_metrics, :events, 1, {:events, 0})
    :ok
  end
end

# Register globally — applies to ALL agents under this runner
runner = ADK.Runner.new(
  app_name: "my_app",
  agent: root_agent,
  plugins: [MetricsPlugin]
)
```

**Built-in plugins**:
- `ADK.Plugin.Logging` — structured logging at each hook point
- `ADK.Plugin.RateLimit` — throttle LLM calls per time window
- `ADK.Plugin.Cache` — cache LLM responses for identical requests
- `ADK.Plugin.ReflectRetry` — validate + retry on failure

**Callbacks vs Plugins**:
| | Callbacks | Plugins |
|---|----------|---------|
| Scope | Per-agent | Global (all agents) |
| Registered on | `LlmAgent` | `Runner` |
| State | Stateless | Carry state via `init/1` |
| Use case | Agent-specific hooks | Cross-cutting concerns |

**Python comparison**: Python ADK's `BasePlugin` is nearly identical in concept.
ADK Elixir uses OTP-friendly state threading through init/before/after.

---

## MCP Tool Integration

Connect to [Model Context Protocol](https://modelcontextprotocol.io/) servers
and use their tools as native ADK tools.

**When to use**: Integrating with MCP-compatible tool servers (databases, APIs, file systems)
without writing custom tool wrappers.

```elixir
# Start an MCP client connected to a server
{:ok, client} = ADK.MCP.Client.start_link(
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/workspace"]
)

# Convert all MCP tools to ADK FunctionTools
{:ok, tools} = ADK.MCP.ToolAdapter.to_adk_tools(client)

# Use them like any other tools
agent = ADK.Agent.LlmAgent.new(
  name: "file_assistant",
  model: "gemini-2.0-flash",
  instruction: """
  You can read and write files. Use the available tools to help
  the user manage their files.
  """,
  tools: tools
)
```

**How it works**:
1. `ADK.MCP.Client` manages the JSON-RPC connection to the MCP server process
2. `ADK.MCP.ToolAdapter.to_adk_tools/1` fetches the tool list and wraps each as a `FunctionTool`
3. Tool calls from the LLM are transparently forwarded to the MCP server
4. Results are returned as standard tool output

**Key points**:
- MCP tools auto-inherit their name, description, and parameter schema from the server
- The MCP client runs as a GenServer — supervised and crash-resilient
- You can mix MCP tools with native ADK tools in the same agent

---

## Structured Output

Force the LLM to return responses conforming to a JSON schema using `output_schema`.

**When to use**: When you need machine-parseable output (API responses, data extraction,
structured analysis) without relying on ReflectRetry validation.

```elixir
agent = ADK.Agent.LlmAgent.new(
  name: "data_extractor",
  model: "gemini-2.0-flash",
  instruction: """
  Extract structured information from the user's text.
  Return a JSON object matching the required schema.
  """,
  output_schema: %{
    type: "object",
    properties: %{
      name: %{type: "string", description: "Person's full name"},
      email: %{type: "string", description: "Email address"},
      company: %{type: "string", description: "Company name"},
      role: %{type: "string", description: "Job title"}
    },
    required: ["name", "email"]
  }
)

# The LLM response will be valid JSON matching the schema
runner = ADK.Runner.new(app_name: "extractor", agent: agent)
events = ADK.Runner.run(runner, "user1", "s1",
  "Hi, I'm Jane Smith (jane@acme.co), CTO at Acme Corp.")

# Parse the structured output
json_text = events |> Enum.map(&ADK.Event.text/1) |> Enum.join("")
{:ok, data} = Jason.decode(json_text)
# => %{"name" => "Jane Smith", "email" => "jane@acme.co", ...}
```

**Key points**:
- `output_schema` is passed to the model via `generate_content_config`
- The model is instructed to respond in JSON matching the schema
- For Gemini models, this uses native structured output (response_mime_type: application/json)
- Combine with `ReflectRetry` for additional validation if needed

**When to use output_schema vs ReflectRetry**:
- `output_schema` — schema enforcement at the model level (cheaper, faster)
- `ReflectRetry` — custom validation logic (format checks, business rules)
- Both together — belt and suspenders

---

## Dynamic Instructions

Use functions instead of static strings for instructions that adapt at runtime.

**When to use**: Instructions that depend on session state, time of day, user preferences,
or external data.

```elixir
# Function-based instruction
agent = ADK.Agent.LlmAgent.new(
  name: "adaptive_assistant",
  model: "gemini-2.0-flash",
  instruction: fn ctx ->
    user_name = ADK.Context.get_state(ctx, "user_name") || "friend"
    hour = DateTime.utc_now().hour

    greeting = cond do
      hour < 12 -> "Good morning"
      hour < 17 -> "Good afternoon"
      true -> "Good evening"
    end

    """
    #{greeting}, #{user_name}!
    You are a helpful assistant. Be concise and friendly.
    The current time is #{DateTime.utc_now() |> Calendar.strftime("%H:%M UTC")}.
    """
  end
)

# MFA tuple — for compile-time safety and hot code reloading
agent = ADK.Agent.LlmAgent.new(
  name: "configurable_agent",
  model: "gemini-2.0-flash",
  instruction: {MyApp.Instructions, :build, ["assistant"]}
)

# In MyApp.Instructions:
defmodule MyApp.Instructions do
  def build(role, ctx) do
    user_prefs = ADK.Context.get_state(ctx, "preferences") || %{}
    tone = Map.get(user_prefs, "tone", "professional")

    """
    You are a #{role}. Respond in a #{tone} tone.
    User preferences: #{inspect(user_prefs)}
    """
  end
end
```

**Instruction types**:
| Type | Example | Use case |
|------|---------|----------|
| String | `"You are helpful."` | Static instructions |
| Template | `"Hello {user_name}."` | State variable interpolation |
| Function | `fn ctx -> ... end` | Dynamic runtime logic |
| MFA tuple | `{Mod, :fun, args}` | Configurable, hot-reloadable |

**Key points**:
- Functions receive the current `ADK.Context` and must return a string
- MFA tuples call `Mod.fun(args..., ctx)` — context is always the last argument
- `global_instruction` on the root agent also supports all instruction types
- Template variables use `{var}` syntax — append `?` for optional: `{maybe?}`

---

## Oban Background Jobs

Run agents as durable background jobs with retries, scheduling, and persistence.

**When to use**: Async processing, scheduled tasks, webhook handlers, email processing,
any agent work that should survive restarts.

```elixir
# Enqueue an agent job
ADK.Oban.AgentWorker.enqueue(
  MyApp.Agents.Summarizer,
  "user1",
  "Summarize the quarterly report",
  app_name: "my_app",
  session_id: "report-q4",
  queue: :agents,
  max_attempts: 3
)

# Or use Oban directly for scheduling
%{
  agent_module: "MyApp.Agents.DailyDigest",
  user_id: "user1",
  message: "Generate today's digest",
  app_name: "my_app"
}
|> ADK.Oban.AgentWorker.new(
  queue: :agents,
  scheduled_at: ~U[2026-03-13 08:00:00Z]
)
|> Oban.insert()

# The agent module just needs to return an agent
defmodule MyApp.Agents.Summarizer do
  def agent do
    ADK.Agent.LlmAgent.new(
      name: "summarizer",
      model: "gemini-2.0-flash",
      instruction: "Summarize the given content concisely.",
      tools: [read_doc_tool()]
    )
  end
end
```

**Key points**:
- Oban is an optional dependency — add `{:oban, "~> 2.17"}` to your deps
- Jobs survive application restarts (backed by PostgreSQL)
- Built-in retries with exponential backoff
- Use Oban's `unique` option to prevent duplicate jobs
- Results can be stored in session state or published via PubSub

**Elixir-only**: Python ADK has no built-in background job support. ADK Elixir
leverages Oban — the standard Elixir job processing library.

See the [Oban Integration guide](oban-integration.md) for full setup.

---

## Phoenix LiveView Integration

Build real-time agent chat UIs with Phoenix LiveView — streaming responses,
tool call visualization, and HITL approval dialogs.

**When to use**: Web-based agent interfaces, internal tools, customer support dashboards.

```elixir
# In your LiveView
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  # ADK provides a handler module for common agent interactions
  use ADK.Phoenix.LiveHandler

  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      messages: [],
      agent: build_agent(),
      runner: build_runner()
    )}
  end

  def handle_event("send_message", %{"message" => msg}, socket) do
    # ADK.Phoenix.LiveHandler provides handle_agent_message/3
    # which streams events back to the LiveView as they arrive
    {:noreply, start_agent_stream(socket, msg)}
  end

  # Renders streaming responses, tool calls, and approval dialogs
  def render(assigns) do
    ~H\"\"\"
    <div id="chat" phx-hook="ChatScroll">
      <%= for msg <- @messages do %>
        <div class={"message " <> msg.role}>
          <%= msg.content %>
          <%= if msg.tool_calls do %>
            <div class="tool-calls">
              <%= for tc <- msg.tool_calls do %>
                <span class="tool-badge"><%= tc.name %></span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    <form phx-submit="send_message">
      <input name="message" placeholder="Ask something..." />
    </form>
    \"\"\"
  end
end
```

**Quick start**: Use the built-in dev server for zero-config chat UI:

```bash
mix adk.server --agent MyApp.Agents.Helper --port 4000
```

This starts a Bandit HTTP server with a dark-themed chat UI, no Phoenix project needed.

**Key points**:
- `ADK.Phoenix.LiveHandler` handles streaming, tool display, and HITL approval
- `ADK.Phoenix.ChatLive` provides a ready-made chat component
- Events stream in real-time via WebSocket — no polling
- HITL approval dialogs render inline in the chat

**Elixir-only**: Python ADK uses `adk web` (Mesop). ADK Elixir uses Phoenix LiveView
for native real-time streaming — no separate frontend framework needed.

See the [Phoenix Integration guide](phoenix-integration.md) and
[Dev Server guide](dev-server.md) for details.

---

## Combining Patterns

Real agents combine multiple patterns. Here's the `claw` example architecture:

```
ADK.Agent.LlmAgent (router)         ← Coordinator pattern
├── ADK.Agent.LlmAgent (coder)      ← Specialist with tools
│   ├── shell_command                ← Tool with Policy guard
│   └── read_file                    ← Simple tool
├── ADK.Agent.LlmAgent (helper)     ← Specialist with tools
│   ├── datetime                     ← Simple tool
│   ├── save_note / list_notes       ← Artifact pattern
│   ├── search_memory                ← Memory pattern
│   ├── call_mock_api                ← Auth pattern
│   └── research                     ← LongRunningTool pattern
├── ADK.Policy.HumanApproval        ← HITL for delete_file
├── ADK.Plugin.ReflectRetry          ← Output validation
├── LoggingCallbacks                 ← Observability
├── ADK.Eval.Case tests              ← Quality gates
└── A2A endpoint                     ← External agent access
```

Start simple (single agent + tools), add patterns as complexity grows.

---

## Pattern Comparison: Python ADK vs Elixir

| Pattern | Python ADK | ADK Elixir | Notes |
|---------|-----------|------------|-------|
| Single Agent | `Agent(tools=[...])` | `LlmAgent.new(tools: [...])` | Equivalent |
| Sequential | `SequentialAgent(sub_agents=[...])` | `SequentialAgent.new(sub_agents: [...])` | Equivalent |
| Parallel | `ParallelAgent(sub_agents=[...])` | `ParallelAgent.new(sub_agents: [...])` | Elixir uses `Task.async_stream` |
| Loop | `LoopAgent(max_iterations=N)` | `LoopAgent.new(max_iterations: N)` | Equivalent |
| Transfer | Single tool, enum param | One tool per sub-agent | Different approach, same result |
| Custom Agent | Inherit `BaseAgent` | Implement `ADK.Agent` protocol | Protocol vs inheritance |
| Callbacks | Class methods | Behaviour modules | Composable chain |
| Policy | Ad-hoc in callbacks | Dedicated `ADK.Policy` behaviour | Elixir-only |
| HITL | Pattern (not API) | `ADK.Policy.HumanApproval` | Elixir-only API |
| Long-running | `is_long_running=True` | `LongRunningTool` + OTP Task | Supervised in Elixir |
| Memory | `MemoryService` ABC | `ADK.Memory` behaviour | Equivalent |
| Artifacts | `ArtifactService` ABC | `ADK.Artifact.Store` behaviour | Equivalent |
| Auth | `AuthRequestProcessor` | Inline `{:error, {:auth_required, ...}}` | Simpler in Elixir |
| A2A | Separate package | Built-in `ADK.A2A` | Integrated in Elixir |
| Skills | `AgentSkill` | `ADK.Skill` | Equivalent |
| Compaction | Token-budget only | 4 strategies | Elixir has more options |
| Eval | pytest-based | ExUnit-based `ADK.Eval.Case` | Equivalent |
| Plugins | `BasePlugin` on Runner | `ADK.Plugin` behaviour | Similar concept |
| MCP | `MCPToolset` | `ADK.MCP.Client` + `ToolAdapter` | Equivalent |
| Structured Output | `output_schema` | `output_schema` on LlmAgent | Equivalent |
| Dynamic Instructions | `Callable[[ReadonlyContext], str]` | `fn ctx -> str` or MFA tuple | Equivalent |
| Background Jobs | None (manual) | `ADK.Oban.AgentWorker` | Elixir-only |
| Real-time UI | Mesop (`adk web`) | Phoenix LiveView | Elixir-only |

---

## Future Work

These patterns exist in the Python ADK ecosystem but aren't yet implemented in ADK Elixir:

- **OpenAPI Toolsets** — auto-generate tools from OpenAPI specs
- **Computer Use** — browser/desktop automation tools
- **Planning** — NL planning and structured plan execution
- **Express Mode** — simplified single-shot API
- **User Simulation** — automated eval with simulated users

See the [design review](../docs/intentional-differences.md) for the full gap analysis.
