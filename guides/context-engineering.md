# Context Engineering in ADK Elixir

A deep dive into how ADK Elixir compiles agent definitions into LLM requests —
and why Elixir is the ideal language for it.

## Why "Context Engineering" > "Prompt Engineering"

Prompt engineering is writing text and hoping the model behaves. Context
engineering is building **structured data pipelines** that compile agent
definitions, session state, conversation history, and runtime context into
precisely shaped LLM requests.

In ADK Elixir, you never write a raw prompt. Instead, you declare agents:

```elixir
LlmAgent.new(
  name: "analyst",
  model: "gemini-flash-latest",
  instruction: "Analyze data for {company_name}. Current quarter: {quarter}.",
  identity: "You are a senior data analyst.",
  global_instruction: "Always respond in JSON.",
  output_schema: %{"type" => "object", "properties" => %{"summary" => %{"type" => "string"}}},
  sub_agents: [researcher(), writer()],
  tools: [search_tool(), calculate_tool()]
)
```

That declaration is **compiled** at runtime into a full LLM request: system
instruction, messages, tool definitions, schemas, transfer instructions — all
assembled automatically. The agent definition is source code. The LLM request
is the compiled output.

This is what makes agents maintainable. You change the declaration. The
compilation pipeline handles the rest.

## Elixir's Pattern Matching Advantage

Python ADK implements context engineering through a chain of 12 request
processor classes, each with a `run_async()` method:

```python
# Python ADK — class-based processors
class InstructionRequestProcessor(BaseRequestProcessor):
    async def run_async(self, request, ctx):
        request.system_instruction = self._compile(ctx)
        return request

class ContentsRequestProcessor(BaseRequestProcessor):
    async def run_async(self, request, ctx):
        request.contents = self._build_contents(ctx)
        return request
```

In Elixir, the same logic fits naturally into pattern matching and pipes:

```elixir
# Elixir ADK — pipeline with pattern matching
defp build_request(ctx, agent) do
  messages = build_messages(ctx)
  all_tools = effective_tools(agent)

  messages = ADK.Context.Compressor.maybe_compress(messages, compressor_opts(agent, ctx))

  {static_instruction, dynamic_instruction} =
    ADK.InstructionCompiler.compile_split(agent, ctx)

  %{
    model: agent.model,
    instruction: compile_instruction(ctx, agent),
    static_system_instruction: static_instruction,
    dynamic_system_instruction: dynamic_instruction,
    messages: messages,
    tools: Enum.map(all_tools, &ADK.Tool.declaration/1)
  }
  |> maybe_add_generate_config(agent, ctx)
  |> maybe_add_output_schema(agent)
end
```

The `build_messages/1` function uses pattern matching on event structs to
transform conversation history:

```elixir
defp build_messages(ctx) do
  ADK.Session.get_events(ctx.session_pid)
  |> Enum.filter(&ADK.Event.on_branch?(&1, ctx.branch))
  |> Enum.map(fn e ->
    cond do
      ADK.Event.compaction?(e) ->
        %{role: :user, parts: (e.content || %{})[:parts] || []}

      e.author == "user" ->
        %{role: :user, parts: (e.content || %{})[:parts] || []}

      e.author == current_agent ->
        %{role: :model, parts: (e.content || %{})[:parts] || []}

      true ->
        reformat_other_agent_message(e)
    end
  end)
end
```

Three things stand out:

1. **Pattern matching on structs** — `ADK.Event.compaction?(e)` checks the
   `author` field. `on_branch?/2` matches on branch paths. No isinstance
   checks, no type coercion.

2. **Pipe-based transformation** — `get_events |> filter |> map` reads
   top-to-bottom. The data flows through the pipeline like water through pipes.

3. **Immutable context threading** — `ctx` is passed through every function
   unchanged. No mutation, no side effects, no "did someone modify the request
   object upstream?" bugs.

## The Compilation Pipeline

Here's the full data flow from agent definition to LLM HTTP request:

```
┌──────────────────────────────────────────────────────────────┐
│                    Agent Definition                           │
│  name, model, instruction, identity, tools, sub_agents       │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│              InstructionCompiler.compile_split/2              │
│                                                              │
│  ┌─────────────────────┐    ┌──────────────────────────┐     │
│  │   Static Parts       │    │   Dynamic Parts           │     │
│  │  • global_instruction │    │  • agent instruction       │     │
│  │  • identity           │    │    (with {var} substitution)│     │
│  │  • transfer targets   │    │  • output_schema instruction│     │
│  └─────────────────────┘    └──────────────────────────┘     │
│                                                              │
│  Dynamic providers resolved: fn ctx -> ... end               │
│  Template vars substituted from session state                │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│                    build_messages/1                           │
│                                                              │
│  Session Events ──► Branch Filter ──► Role Assignment        │
│                                                              │
│  • Events filtered by branch path (on_branch?/2)            │
│  • User events → role: :user                                │
│  • Current agent events → role: :model                      │
│  • Other agent events → reformatted as "[name] said: ..."   │
│  • Compaction events → role: :user (summaries)              │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│              Context Compression (optional)                   │
│                                                              │
│  Truncate │ SlidingWindow │ Summarize │ TokenBudget          │
│                                                              │
│  Applied via maybe_compress/2 based on agent config          │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│                   LLM Request Assembly                       │
│                                                              │
│  %{                                                          │
│    model: "gemini-flash-latest",                             │
│    instruction: "...",               # full compiled text    │
│    static_system_instruction: "...", # cacheable portion     │
│    dynamic_system_instruction: "...",# per-request portion   │
│    messages: [...],                  # compressed history    │
│    tools: [...],                     # tool declarations     │
│    generate_content_config: %{...},  # temperature, etc.     │
│    output_schema: %{...}             # if structured output  │
│  }                                                           │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│               LLM Backend (Gemini / Anthropic / OpenAI)      │
│                                                              │
│  Translates generic request → provider-specific HTTP call    │
└──────────────────────────────────────────────────────────────┘
```

Each stage is a pure function. The pipeline is easy to test, easy to debug,
and impossible to corrupt through mutation.

## Branch-Aware History

Multi-agent conversations create a tree of events. Without branch filtering,
agent B would see agent C's internal tool calls — confusing both the model
and the conversation flow.

ADK Elixir uses **dot-delimited branch paths** to keep conversations clean.

### How Branches Work

```
root                    ← top-level agent
root.router             ← router agent
root.router.weather     ← weather specialist
root.router.news        ← news specialist
```

When the weather agent runs, it sees:

- ✅ Events with `branch: nil` (universal — user messages)
- ✅ Events with `branch: "root"` (ancestor)
- ✅ Events with `branch: "root.router"` (ancestor)
- ✅ Events with `branch: "root.router.weather"` (own branch)
- ❌ Events with `branch: "root.router.news"` (sibling — filtered out)

### The Implementation

`Event.on_branch?/2` is elegant in its simplicity:

```elixir
def on_branch?(%Event{branch: nil}, _current_branch), do: true
def on_branch?(%Event{}, nil), do: true

def on_branch?(%Event{branch: event_branch}, current_branch)
    when is_binary(event_branch) and is_binary(current_branch) do
  event_branch == current_branch or
    String.starts_with?(current_branch, event_branch <> ".")
end
```

Three clauses. No loops, no tree traversal, no parent lookups. Just string
prefix matching on dot-delimited paths.

### Three-Agent Scenario

Let's trace a conversation with a router, weather agent, and news agent:

```elixir
# Define the agents
weather = LlmAgent.new(
  name: "weather",
  model: "gemini-flash-latest",
  instruction: "Provide weather forecasts.",
  tools: [weather_tool()]
)

news = LlmAgent.new(
  name: "news",
  model: "gemini-flash-latest",
  instruction: "Summarize current news.",
  tools: [news_tool()]
)

router = LlmAgent.new(
  name: "router",
  model: "gemini-flash-latest",
  instruction: "Route requests to weather or news agents.",
  sub_agents: [weather, news]
)
```

When user asks "What's the weather in NYC?" followed by "Any tech news?":

```
Event 1: author=user, branch=nil, text="Weather in NYC?"
  └─ Visible to: everyone (branch: nil)

Event 2: author=router, branch="root.router", text="Delegating to weather..."
  └─ Visible to: router, weather, news (ancestor path)

Event 3: author=weather, branch="root.router.weather", tool_call=get_weather(NYC)
  └─ Visible to: weather only (own branch)

Event 4: author=weather, branch="root.router.weather", text="NYC: 72°F, sunny"
  └─ Visible to: weather only (own branch)

Event 5: author=user, branch=nil, text="Any tech news?"
  └─ Visible to: everyone

Event 6: author=router, branch="root.router", text="Delegating to news..."
  └─ Visible to: router, weather, news

Event 7: author=news, branch="root.router.news", tool_call=get_news(tech)
  └─ Visible to: news only
```

When the news agent builds its messages, it sees Events 1, 2, 5, 6, 7 — but
**never** Events 3 and 4. The weather agent's tool calls are invisible to the
news agent. Clean context, no cross-contamination.

### Branching in Context

Context branching happens automatically when agents delegate:

```elixir
# ADK.Context.for_child/2 extends the branch path
def for_child(%__MODULE__{} = ctx, agent_spec) do
  child_name = ADK.Agent.name(agent_spec)
  child_branch = if ctx.branch, do: "#{ctx.branch}.#{child_name}", else: child_name
  %{ctx | agent: agent_spec, branch: child_branch, temp_state: %{}}
end

# ADK.Context.fork_branch/2 for parallel agents
def fork_branch(%__MODULE__{branch: parent} = ctx, child_name) do
  branch = if parent, do: "#{parent}.#{child_name}", else: child_name
  %{ctx | branch: branch, temp_state: %{}}
end
```

You never manage branches manually. The framework handles it.

## Dynamic Instructions

Static instructions are fine for simple agents. Real-world agents need
instructions that change based on context — time of day, user preferences,
conversation state, external conditions.

ADK Elixir supports three forms of instruction providers:

### Anonymous Functions

```elixir
LlmAgent.new(
  name: "assistant",
  model: "gemini-flash-latest",
  instruction: fn ctx ->
    hour = DateTime.utc_now().hour

    base = "You are a helpful assistant."

    time_context = cond do
      hour < 6 -> "The user is likely working late. Be concise."
      hour < 12 -> "Good morning energy. Be upbeat."
      hour < 18 -> "Afternoon focus. Be efficient."
      true -> "Evening wind-down. Be relaxed."
    end

    # Access session state for user preferences
    state = ADK.Session.get_all_state(ctx.session_pid)
    lang_pref = Map.get(state, "preferred_language", "English")

    "#{base}\n#{time_context}\nRespond in #{lang_pref}."
  end
)
```

### MFA (Module-Function-Args) Providers

For testable, reusable instruction logic:

```elixir
defmodule MyApp.Instructions do
  def for_user(ctx) do
    state = ADK.Session.get_all_state(ctx.session_pid)
    tier = Map.get(state, "user_tier", "free")

    case tier do
      "premium" -> "You have access to all features. Be thorough."
      "enterprise" -> "You are in enterprise mode. Follow compliance guidelines."
      _ -> "You are in free mode. Suggest upgrades when relevant."
    end
  end

  def with_expertise(ctx, domain) do
    "You are an expert in #{domain}. " <> for_user(ctx)
  end
end

# Usage
LlmAgent.new(
  name: "analyst",
  model: "gemini-flash-latest",
  instruction: {MyApp.Instructions, :for_user}
)

# With extra args
LlmAgent.new(
  name: "legal_analyst",
  model: "gemini-flash-latest",
  instruction: {MyApp.Instructions, :with_expertise, ["contract law"]}
)
```

### How Resolution Works

`InstructionCompiler.resolve_provider/2` handles all three forms:

```elixir
def resolve_provider(instruction, _ctx) when is_binary(instruction), do: instruction
def resolve_provider(fun, ctx) when is_function(fun, 1), do: safe_call(fn -> fun.(ctx) end)
def resolve_provider({mod, fun_name}, ctx), do: safe_call(fn -> apply(mod, fun_name, [ctx]) end)
def resolve_provider({mod, fun_name, args}, ctx), do: safe_call(fn -> apply(mod, fun_name, [ctx | args]) end)
```

Pattern matching dispatches to the right resolution strategy. If a provider
raises, the error is logged and an empty string is used — the agent still
responds rather than crashing.

## Template Variable Substitution

Instructions support `{key}` template variables that are filled from session
state at compile time:

```elixir
LlmAgent.new(
  name: "support",
  model: "gemini-flash-latest",
  instruction: """
  You are helping {user_name} with their {plan_type} account.
  Their account ID is {account_id}.
  Priority level: {priority}.
  """
)
```

Before an LLM call, the runner populates session state:

```elixir
# Set state before or during the session
ADK.Session.set_state(session_pid, "user_name", "Alice")
ADK.Session.set_state(session_pid, "plan_type", "enterprise")
ADK.Session.set_state(session_pid, "account_id", "ENT-12345")
ADK.Session.set_state(session_pid, "priority", "high")
```

The substitution engine replaces `{key}` patterns:

```elixir
def substitute_vars(instruction, state) when is_binary(instruction) and is_map(state) do
  Regex.replace(~r/\{(\w+)\}/, instruction, fn full_match, key ->
    case Map.get(state, key) || Map.get(state, String.to_existing_atom(key)) do
      nil -> full_match  # Leave unresolved vars as-is
      value -> to_string(value)
    end
  end)
end
```

The flow: **Session State → `substitute_vars/2` → Resolved Instruction → LLM**

Unresolved variables are left as literal text (e.g., `{unknown_key}`) rather
than raising — this is defensive by design, so missing state doesn't crash
the agent.

## Context Compression Strategies

Long conversations exceed token limits. ADK Elixir provides four compression
strategies, each suited to different scenarios.

### Strategy Overview

| Strategy | Approach | Best For |
|----------|----------|----------|
| `Truncate` | Keep last N messages | Simple chatbots, prototypes |
| `SlidingWindow` | Keep last N invocations (preserves tool call pairs) | Tool-heavy agents |
| `Summarize` | LLM-summarize old messages, keep recent verbatim | Long conversations needing full context |
| `TokenBudget` | Fill a token budget newest-first | Production agents with token cost limits |

### Decision Tree

```
Need to stay within a specific token budget?
├── Yes → TokenBudget
└── No
    ├── Agent uses many tools?
    │   ├── Yes → SlidingWindow (invocation-aware, won't orphan tool responses)
    │   └── No
    │       ├── Context matters a lot? (e.g., multi-session support agent)
    │       │   ├── Yes → Summarize (preserves context in compressed form)
    │       │   └── No → Truncate (simplest, cheapest)
    └── Combine: TokenBudget as outer limit + any inner strategy
```

### Configuration Examples

```elixir
# Simple truncation — last 20 messages
LlmAgent.new(
  name: "chatbot",
  model: "gemini-flash-latest",
  instruction: "You are a helpful chatbot.",
  context_compressor: [
    strategy: {ADK.Context.Compressor.Truncate, [max_messages: 20]},
    threshold: 25  # Only compress when > 25 messages
  ]
)

# Sliding window — last 5 user invocations with all their tool calls
LlmAgent.new(
  name: "tool_agent",
  model: "gemini-flash-latest",
  instruction: "You have many tools.",
  tools: many_tools(),
  context_compressor: [
    strategy: {ADK.Context.Compressor.SlidingWindow, [invocations: 5]},
    threshold: 0  # Always apply
  ]
)

# LLM summarization — keep last 5 verbatim, summarize everything older
LlmAgent.new(
  name: "support",
  model: "gemini-flash-latest",
  instruction: "You are a support agent.",
  context_compressor: [
    strategy: {ADK.Context.Compressor.Summarize, [keep_recent: 5]},
    threshold: 10,
    context: %{model: "gemini-flash-latest"}
  ]
)

# Token budget — stay within 4000 tokens
LlmAgent.new(
  name: "efficient",
  model: "gemini-flash-latest",
  instruction: "Be concise.",
  context_compressor: [
    strategy: {ADK.Context.Compressor.TokenBudget, [
      token_budget: 4000,
      chars_per_token: 4,  # Rough estimate (same as Python ADK)
      keep_recent: 3
    ]},
    threshold: 0  # Token budget handles its own thresholding
  ]
)
```

### How TokenBudget Works

The token budget strategy mirrors Python ADK's `_estimate_prompt_token_count`:

1. System messages and the N most recent messages are always kept
2. Their token cost is deducted from the budget
3. Remaining older messages are added newest-first until the budget is exhausted
4. Messages that don't fit are dropped

Token estimation uses `total_chars ÷ chars_per_token` (default: 4 chars per
token). This is a rough heuristic — good enough for budget management without
requiring an external tokenizer.

## Static vs Dynamic Instruction Separation

`InstructionCompiler.compile_split/2` separates instructions into two buckets:

```elixir
def compile_split(agent, ctx) do
  static_parts = [
    global_instruction(agent, ctx),  # Rarely changes
    identity_instruction(agent),      # Never changes
    transfer_instruction(agent)       # Changes only with agent topology
  ]

  dynamic_parts = [
    agent_instruction(agent, ctx),    # Has {var} substitution, may use fn/MFA
    output_schema_instruction(agent)  # May change per-request
  ]

  {join(static_parts), join(dynamic_parts)}
end
```

### Why This Matters: Gemini Context Caching

Gemini's API supports **context caching** — you send static content once, get
a cache token back, and reference it in subsequent requests. This saves both
latency and cost for large system instructions.

The split enables this pattern:

```elixir
# First request: send static instruction, get cache handle
{static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

# The LLM backend can cache `static` across requests
# and only send `dynamic` fresh each time

request = %{
  static_system_instruction: static,   # Cached by Gemini
  dynamic_system_instruction: dynamic, # Sent fresh each call
  messages: messages
}
```

For agents with large global instructions (compliance rules, knowledge bases,
few-shot examples), this can reduce token costs by 50-80% on subsequent calls.

### Design Guideline

Put stable content in `global_instruction` and `identity`. Put per-request
content in `instruction` with `{var}` templates or `fn ctx ->` providers:

```elixir
LlmAgent.new(
  name: "compliance_bot",
  model: "gemini-flash-latest",
  # Static — cached, sent once
  global_instruction: """
  COMPLIANCE RULES (version 2024.3):
  1. Never recommend specific financial products...
  2. Always include risk disclaimers...
  ... (500 lines of regulations) ...
  """,
  identity: "You are a licensed financial advisor assistant.",
  # Dynamic — fresh each request
  instruction: fn ctx ->
    state = ADK.Session.get_all_state(ctx.session_pid)
    region = Map.get(state, "user_region", "US")
    "Apply #{region}-specific regulations. Current session risk tolerance: {risk_level}."
  end
)
```

## Other-Agent Message Reformatting

When agent B reads messages from agent A, the raw events could be confusing —
whose tool calls are whose? ADK Elixir reformats other-agent messages to
maintain clarity:

```elixir
defp reformat_other_agent_message(event) do
  agent_name = event.author || "unknown"
  parts = (event.content || %{})[:parts] || []

  reformatted_parts =
    Enum.flat_map(parts, fn
      %{text: text} when is_binary(text) ->
        [%{text: "[#{agent_name}] said: #{text}"}]

      %{function_call: %{name: fname, args: args}} ->
        args_str = if is_map(args), do: Jason.encode!(args), else: inspect(args)
        [%{text: "[#{agent_name}] called tool `#{fname}` with parameters: #{args_str}"}]

      %{function_response: %{name: fname, response: resp}} ->
        resp_str = if is_binary(resp), do: resp, else: inspect(resp)
        [%{text: "[#{agent_name}] tool `#{fname}` returned: #{resp_str}"}]

      other -> [other]
    end)

  %{role: :user, parts: reformatted_parts}
end
```

This produces clear, attributable context:

```
[weather] said: The temperature in NYC is 72°F and sunny.
[weather] called tool `get_forecast` with parameters: {"city":"NYC","days":3}
[weather] tool `get_forecast` returned: {"forecast":"Sunny through Thursday"}
```

The router agent sees exactly what happened without confusion about whose
tool calls belong to whom.

**Note:** Reformatted messages become `role: :user` messages. This is
intentional — the model only "owns" messages with `role: :model`. Everything
else is context from the outside world.

## Recipes

### Recipe 1: Memory-Aware Agent

An agent that remembers past sessions and adjusts its behavior:

```elixir
defmodule MyApp.MemoryAgent do
  def build do
    LlmAgent.new(
      name: "memory_agent",
      model: "gemini-flash-latest",
      instruction: fn ctx ->
        # Fetch memories from previous sessions
        memories = case ctx.app_name do
          nil -> []
          app ->
            {:ok, entries} = ADK.Memory.InMemory.search(
              ADK.Memory.InMemory,
              app,
              ctx.user_id,
              "recent context"
            )
            entries
        end

        memory_context = case memories do
          [] -> "This is a new user. Be welcoming."
          entries ->
            summary = Enum.map_join(entries, "\n", & &1.text)
            "Previous context:\n#{summary}\n\nUse this to personalize your responses."
        end

        """
        You are a personal assistant with memory across sessions.
        #{memory_context}
        The user's name is {user_name}.
        """
      end
    )
  end
end
```

### Recipe 2: Time-Sensitive Instructions

An agent whose capabilities change based on business hours:

```elixir
defmodule MyApp.SupportAgent do
  def build do
    LlmAgent.new(
      name: "support",
      model: "gemini-flash-latest",
      instruction: fn _ctx ->
        now = DateTime.utc_now()
        hour = now.hour
        day = Date.day_of_week(now)

        cond do
          day in [6, 7] ->
            """
            Weekend mode. You can help with general questions but cannot
            process refunds or account changes. Direct urgent issues to
            Monday support.
            """

          hour >= 9 and hour < 17 ->
            """
            Business hours. Full capabilities available. You can process
            refunds up to $100 and make account changes.
            """

          true ->
            """
            After hours. You can help with general questions and create
            tickets for the morning team. No account modifications.
            """
        end
      end,
      tools: fn _ctx ->
        # Could also make tools dynamic based on the same conditions
        [general_faq(), create_ticket()]
      end
    )
  end
end
```

### Recipe 3: Progressive Disclosure

An agent that reveals more capabilities as the conversation deepens:

```elixir
defmodule MyApp.ProgressiveAgent do
  def build do
    LlmAgent.new(
      name: "guide",
      model: "gemini-flash-latest",
      instruction: fn ctx ->
        event_count = if ctx.session_pid do
          ADK.Session.get_events(ctx.session_pid) |> length()
        else
          0
        end

        base = "You are a coding tutor."

        case event_count do
          n when n < 4 ->
            base <> """
            The student just started. Keep things simple. Use basic examples.
            Don't mention advanced topics yet.
            """

          n when n < 12 ->
            base <> """
            The student is warming up. You can introduce intermediate concepts.
            Start mentioning patterns and best practices.
            """

          _ ->
            base <> """
            Extended conversation. The student is engaged. Feel free to discuss
            advanced topics, trade-offs, and architectural decisions.
            """
        end
      end
    )
  end
end
```

### Recipe 4: Context-Efficient Multi-Agent Pipeline

A pipeline that uses TokenBudget compression and branch isolation together:

```elixir
defmodule MyApp.Pipeline do
  def build do
    researcher = LlmAgent.new(
      name: "researcher",
      model: "gemini-flash-latest",
      instruction: "Research the topic thoroughly. Output key findings.",
      tools: [search_tool()],
      context_compressor: [
        strategy: {ADK.Context.Compressor.TokenBudget, [token_budget: 8000]},
        threshold: 0
      ]
    )

    writer = LlmAgent.new(
      name: "writer",
      model: "gemini-flash-latest",
      instruction: "Write a clear article from the research findings.",
      context_compressor: [
        strategy: {ADK.Context.Compressor.SlidingWindow, [invocations: 3]},
        threshold: 0
      ]
    )

    editor = LlmAgent.new(
      name: "editor",
      model: "gemini-flash-latest",
      instruction: "Edit for clarity, grammar, and tone. Output the final version."
    )

    # Sequential pipeline — each agent sees only its branch
    ADK.Agent.SequentialAgent.new(
      name: "content_pipeline",
      agents: [researcher, writer, editor]
    )
  end
end
```

Each agent in the pipeline gets its own branch. The writer sees the
researcher's output (via branch ancestry) but the editor doesn't see the
researcher's raw tool calls — only the writer's polished output.

### Recipe 5: State-Driven Agent Personality

An agent that adapts its personality based on accumulated session state:

```elixir
defmodule MyApp.AdaptiveAgent do
  def build do
    LlmAgent.new(
      name: "adaptive",
      model: "gemini-flash-latest",
      instruction: """
      You are a helpful assistant.
      Communication style: {communication_style}
      Expertise level to target: {expertise_level}
      Topics the user is interested in: {interests}
      """,
      # State is set by the agent itself via tool calls
      tools: [
        ADK.Tool.FunctionTool.new(
          name: "set_preference",
          description: "Update user preference after learning about them",
          function: fn args, ctx ->
            key = args["key"]
            value = args["value"]
            ADK.Session.set_state(ctx.session_pid, key, value)
            "Preference #{key} set to #{value}"
          end
        )
      ]
    )
  end
end
```

The agent calls `set_preference` to update state like `communication_style`
or `expertise_level`. On the next turn, the instruction template
automatically picks up the new values.

### Recipe 6: Compaction-Aware Long Session

An agent designed for very long sessions (100+ turns) with smart compaction:

```elixir
defmodule MyApp.LongSession do
  def build do
    LlmAgent.new(
      name: "marathon",
      model: "gemini-flash-latest",
      global_instruction: """
      IMPORTANT: This is a long-running session. You may see summarized
      history from earlier in the conversation. Trust the summaries —
      they were generated by an LLM from the actual conversation.
      """,
      instruction: """
      You are helping {user_name} with project {project_name}.
      Current phase: {project_phase}.
      """,
      context_compressor: [
        strategy: {ADK.Context.Compressor.Summarize, [
          keep_recent: 8,
          summary_instruction: """
          Summarize this conversation segment. Preserve:
          - Key decisions made
          - Action items agreed upon
          - Important facts and numbers
          - Current project status
          Be concise but complete.
          """
        ]},
        threshold: 15,
        context: %{model: "gemini-flash-latest"}
      ]
    )
  end
end
```

## Why Elixir is a Better Home for Context Engineering

The patterns above showcase several Elixir advantages:

1. **Pattern matching on events** — `cond` with struct matching is clearer
   than Python's if/elif chains or isinstance checks. The `on_branch?/2`
   implementation is three clauses of pure logic.

2. **Pipe-based transformations** — `events |> filter |> map |> compress`
   reads as a data pipeline. Python requires intermediate variables or nested
   function calls.

3. **Immutable context threading** — `ctx` flows through the pipeline
   unchanged. No mutation means no "who modified my context?" debugging
   sessions.

4. **MFA tuples for providers** — `{Module, :function, [args]}` is a
   first-class concept in Elixir. In Python, you'd use lambdas or callable
   classes — less inspectable, less testable.

5. **GenServer sessions** — Session state lives in a GenServer process,
   accessed via `get_all_state/1`. This is naturally concurrent — multiple
   agents can read session state simultaneously without locks.

6. **OTP supervision** — If a context compilation step fails, the agent
   process crashes and its supervisor restarts it. In Python, you need
   try/except chains and manual recovery logic.

7. **Compile-time guarantees** — Elixir's compiler catches misspelled module
   names, missing functions, and struct field errors before runtime. Python
   discovers these in production.

Context engineering is fundamentally about **data transformation** — taking
structured declarations and compiling them into LLM requests. Elixir was
built for exactly this kind of work.

## Further Reading

- [Context Compilation](context-compilation.md) — The compilation pipeline reference
- [Agent Patterns](agent-patterns.md) — 25 agent design patterns with code
- [Intentional Differences](../docs/intentional-differences.md) — Why ADK Elixir diverges from Python
