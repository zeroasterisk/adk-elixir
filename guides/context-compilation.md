# Context Compilation

ADK Elixir compiles your agent definition into a coherent LLM request at runtime.
You declare *what* the agent is — the framework figures out *how* to prompt the model.

## The Big Picture

When you define an agent:

```elixir
agent = ADK.Agent.LlmAgent.new(
  name: "weather_bot",
  model: "gemini-flash-latest",
  instruction: "You help users with weather. The user is in {location}.",
  tools: [WeatherTool],
  sub_agents: [DetailAgent]
)
```

You're writing **structured data**, not a prompt. At request time, ADK compiles this
declaration + runtime context into a single LLM request:

```
┌─────────────────────────────────────────────────────┐
│                    LLM Request                      │
├─────────────────────────────────────────────────────┤
│ System Instruction:                                 │
│   "You help users with weather. The user is in NYC."│
│   "You are weather_bot."                            │
│   "You can transfer to: detail_agent"               │
│                                                     │
│ Messages:                                           │
│   [{role: user, text: "What's the forecast?"}]      │
│                                                     │
│ Tools:                                              │
│   [get_weather, transfer_to_agent]                  │
│                                                     │
│ Config:                                             │
│   temperature: 0.3                                  │
└─────────────────────────────────────────────────────┘
```

This is analogous to a compiler:

| Compiler Stage | ADK Equivalent |
|---|---|
| Source code | Agent definition (`%LlmAgent{}`) |
| Intermediate representation | `ADK.Context` + request map being built |
| Target code | LLM API request (Gemini, Anthropic, OpenAI) |
| Optimization passes | Compaction, config merging, schema injection |

## How Compilation Works

The compilation happens in `ADK.Agent.LlmAgent.build_request/2`, which orchestrates
several components:

### 1. Instruction Compilation

`ADK.InstructionCompiler.compile/2` merges multiple instruction sources in order:

```elixir
# lib/adk/instruction_compiler.ex
def compile(agent, ctx) do
  [
    global_instruction(agent, ctx),   # 1. Root-level instructions
    identity_instruction(agent),       # 2. "You are <name>. <description>"
    agent_instruction(agent, ctx),     # 3. Agent's own instruction
    output_schema_instruction(agent),  # 4. JSON schema constraint
    transfer_instruction(agent)        # 5. Sub-agent routing info
  ]
  |> Enum.reject(&is_nil/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.join("\n\n")
end
```

Each component:

- **Global instruction** — Shared across all agents in the tree. Set on the root agent.
- **Identity** — Auto-generated: `"You are weather_bot. Helps users with weather queries."`
- **Agent instruction** — Your custom instruction, with `{variables}` substituted from session state.
- **Output schema** — If set, appends: `"Reply with valid JSON matching this schema: {...}"`
- **Transfer instruction** — If sub-agents exist, lists them with descriptions and explains how to use `transfer_to_agent`.

### 2. Template Variable Substitution

Instructions support `{key}` placeholders resolved from session state:

```elixir
agent = ADK.Agent.LlmAgent.new(
  name: "greeter",
  model: "gemini-flash-latest",
  instruction: "Greet the user. Their name is {user_name} and they speak {language}."
)

# At runtime, if session state = %{"user_name" => "Alice", "language" => "French"}
# The compiled instruction becomes:
# "Greet the user. Their name is Alice and they speak French."
```

Variables are resolved via `ADK.InstructionCompiler.substitute_vars/2`:

```elixir
iex> ADK.InstructionCompiler.substitute_vars("Hello {name}!", %{"name" => "World"})
"Hello World!"

# Missing variables are left as-is (no crash):
iex> ADK.InstructionCompiler.substitute_vars("Hello {name}!", %{})
"Hello {name}!"
```

### 3. Dynamic Instructions (InstructionProvider)

Both `instruction` and `global_instruction` accept dynamic providers:

```elixir
# Anonymous function
agent = ADK.Agent.LlmAgent.new(
  name: "bot",
  model: "gemini-flash-latest",
  instruction: fn ctx ->
    time = DateTime.utc_now() |> DateTime.to_string()
    "You are a bot. Current time: #{time}."
  end
)

# MFA tuple
agent = ADK.Agent.LlmAgent.new(
  name: "bot",
  model: "gemini-flash-latest",
  instruction: {MyApp.Instructions, :build_instruction}
)

# MFA with extra args
agent = ADK.Agent.LlmAgent.new(
  name: "bot",
  model: "gemini-flash-latest",
  instruction: {MyApp.Instructions, :build_instruction, ["formal"]}
)
```

Providers are resolved at runtime before template substitution, so the returned
string can still contain `{variable}` placeholders.

### 4. Tool Collection

`effective_tools/1` combines the agent's declared tools with auto-generated transfer tools:

```elixir
def effective_tools(agent) do
  transfer_tools =
    case agent.sub_agents do
      [] -> []
      subs -> ADK.Tool.TransferToAgent.tools_for_sub_agents(subs)
    end

  agent.tools ++ transfer_tools
end
```

If an agent has sub-agents, `transfer_to_agent` is automatically available.
The LLM sees it as a regular function call — it doesn't know about the multi-agent
architecture.

### 5. Message History Assembly

Session events are converted to LLM messages:

```elixir
# Each session event becomes a message:
# - Events authored by "user" → role: :user
# - Events authored by agents → role: :model
# - User's current message is appended last
```

### 6. Context Compression

If `context_compressor` is configured, messages are compressed before sending:

```elixir
agent = ADK.Agent.LlmAgent.new(
  name: "bot",
  model: "gemini-flash-latest",
  instruction: "Help the user.",
  context_compressor: [
    strategy: ADK.Context.Compressor.TokenBudget,
    token_budget: 4096,
    keep_recent: 3
  ]
)
```

The `TokenBudget` strategy estimates token count and keeps the most recent messages
within budget, dropping older ones.

### 7. Config Merging

Generation config flows from two sources:

```elixir
# Agent defaults (set at definition time)
agent = ADK.Agent.LlmAgent.new(
  # ...
  generate_config: %{temperature: 0.7, max_tokens: 1024}
)

# RunConfig overrides (set at runtime)
run_config = %ADK.RunConfig{
  generate_config: %{temperature: 0.3}  # Overrides agent's 0.7
}
```

The merge strategy: `Map.merge(agent_config, run_config)` — RunConfig wins on conflicts.

## Multi-Agent Transfer

When an agent has sub-agents, the compilation automatically:

1. **Generates transfer instructions** listing available agents:
   ```
   You can delegate tasks to the following agents using the transfer_to_agent tool:
   - detail_agent: Provides detailed weather analysis
   - alert_agent: Handles severe weather alerts
   ```

2. **Creates a `transfer_to_agent` tool** the LLM can call:
   ```json
   {
     "name": "transfer_to_agent",
     "parameters": {
       "properties": {
         "agent_name": {"type": "string"}
       }
     }
   }
   ```

3. **Handles the transfer** when the LLM calls the tool:
   - Creates a child context for the target agent
   - Runs the target agent
   - Returns combined events

### Example: What the LLM Actually Sees

For a router agent with two sub-agents:

```elixir
router = ADK.Agent.LlmAgent.new(
  name: "router",
  model: "gemini-flash-latest",
  instruction: "Route requests to the right specialist.",
  sub_agents: [
    ADK.Agent.LlmAgent.new(
      name: "weather",
      model: "gemini-flash-latest",
      instruction: "You handle weather queries.",
      description: "Handles weather-related questions",
      tools: [WeatherTool]
    ),
    ADK.Agent.LlmAgent.new(
      name: "news",
      model: "gemini-flash-latest",
      instruction: "You handle news queries.",
      description: "Handles news-related questions",
      tools: [NewsTool]
    )
  ]
)
```

The compiled system instruction for `router`:
```
Route requests to the right specialist.

You are router.

You can delegate tasks to the following agents using the transfer_to_agent tool:
- weather: Handles weather-related questions
- news: Handles news-related questions

To transfer to an agent, call the transfer_to_agent tool with the agent's name.
```

The tools list:
```
[transfer_to_agent(agent_name: string)]
```

## Debugging Compilation

To see what the LLM actually receives, inspect the compiled request:

```elixir
# In your agent's before_model callback:
agent = ADK.Agent.LlmAgent.new(
  name: "debug_bot",
  model: "gemini-flash-latest",
  instruction: "Help the user. User is {user_name}."
)

# Or use the context_compilation example to see full output:
# mix run --no-halt
# (in the examples/context_compilation directory)
```

The `examples/context_compilation` project in this repository demonstrates
compilation with debug output showing exactly what each stage produces.

## Comparison with Python ADK

ADK Elixir and Python ADK share the same conceptual model but differ in implementation:

| Aspect | Python ADK | ADK Elixir |
|---|---|---|
| Architecture | 12+ request processor classes in a pipeline | Single `InstructionCompiler` module + `build_request` function |
| Instruction assembly | Incremental `append_instructions()` calls | List comprehension → `Enum.join` |
| Variable substitution | Async with artifact support, optional `{key?}` | Sync, session state only |
| Transfer direction | Bidirectional (parent ↔ child ↔ peer) | Downward only (parent → child) |
| Content filtering | Branch-aware, rewind support, event type filtering | Simple event → message conversion |
| Extensibility | Add processors to the pipeline | Modify `compile/2` or `build_request/2` |

The Elixir implementation is more concise (functional style vs OOP pipeline) while
covering the most common use cases. The Python ADK's additional complexity handles
edge cases like bidirectional transfer, branch isolation in deep agent trees, and
context caching optimization.
