# ADK Elixir — Quick Reference Cheatsheet

Fast lookup for common patterns. For full docs see [GitHub Pages](https://zeroasterisk.github.io/adk-elixir/).

---

## Agents

### Create an LLM Agent

```elixir
alias ADK.Agent.LlmAgent

agent = LlmAgent.new(
  name: "assistant",
  model: "gemini-2.0-flash",
  instruction: "You are a helpful assistant.",
  description: "General-purpose assistant",
  tools: []
)
```

### Sequential Agent (pipeline)

```elixir
alias ADK.Agent.SequentialAgent

pipeline = SequentialAgent.new(
  name: "pipeline",
  sub_agents: [researcher, writer, editor]
)
```

### Parallel Agent (fan-out)

```elixir
alias ADK.Agent.ParallelAgent

fan = ParallelAgent.new(
  name: "fan_out",
  sub_agents: [agent_a, agent_b, agent_c]
)
```

### Loop Agent (until done)

```elixir
alias ADK.Agent.LoopAgent

loop = LoopAgent.new(
  name: "refiner",
  sub_agents: [draft_agent, critique_agent],
  max_iterations: 5
)
```

---

## Runner

### Build and Run

```elixir
runner = ADK.Runner.new(
  app_name: "my_app",
  agent: agent
)

# Returns a list of %ADK.Event{} structs
events = ADK.Runner.run(runner, "user_id", "session_id", "Hello!")
```

### With Persistent Session Store

```elixir
runner = ADK.Runner.new(
  app_name: "my_app",
  agent: agent,
  session_store: {ADK.Session.Store.ETS, []}
)
```

### Top-Level Shortcuts

```elixir
# Create agent + runner + run in one call
agent = ADK.new("bot", model: "gemini-2.0-flash", instruction: "Help")

# Blocking call — returns the text reply
text = ADK.chat(agent, "What is Elixir?")

# Full event list
events = ADK.run(agent, "Tell me about OTP")
```

---

## Tools

### Function Tool (simplest)

```elixir
defmodule MyApp.Tools.Weather do
  @behaviour ADK.Tool

  @impl true
  def name, do: "get_weather"

  @impl true
  def description, do: "Returns current weather for a city."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{city: %{type: "string", description: "City name"}},
      required: ["city"]
    }
  end

  @impl true
  def run(_ctx, %{"city" => city}) do
    {:ok, "Sunny and 72°F in #{city}"}
  end
end
```

Pass to agent:

```elixir
agent = LlmAgent.new(
  name: "weather_bot",
  model: "gemini-2.0-flash",
  instruction: "You can check the weather.",
  tools: [MyApp.Tools.Weather]
)
```

---

## Callbacks

### Behaviour

```elixir
defmodule MyApp.Callbacks.Logger do
  @behaviour ADK.Callback

  @impl true
  def before_agent(ctx), do: {:cont, ctx}

  @impl true
  def after_agent(events, _ctx) do
    IO.puts("Agent produced #{length(events)} events")
    events
  end

  @impl true
  def before_model(ctx), do: {:cont, ctx}

  @impl true
  def after_model(response, _ctx), do: response

  @impl true
  def on_model_error(err, _ctx), do: {:error, err}

  @impl true
  def before_tool(ctx), do: {:cont, ctx}

  @impl true
  def after_tool(result, _ctx), do: result

  @impl true
  def on_tool_error(err, _ctx), do: {:error, err}
end
```

Attach at runtime:

```elixir
events = ADK.Runner.run(runner, user_id, session_id, msg,
  callbacks: [MyApp.Callbacks.Logger]
)
```

### Halt from Callback

```elixir
def before_agent(_ctx) do
  {:halt, []}  # short-circuit — agent never runs
end

def before_model(_ctx) do
  response = %{content: %{parts: [%{text: "cached answer"}]}}
  {:halt, {:ok, response}}  # skip LLM call
end
```

---

## State

### Read / Write in Tool

```elixir
def run(ctx, args) do
  value = ADK.ToolContext.get_state(ctx, :counter, 0)
  ADK.ToolContext.put_state(ctx, :counter, value + 1)
  {:ok, "counter: #{value + 1}"}
end
```

### Save Agent Output to State

```elixir
agent = LlmAgent.new(
  name: "summarizer",
  model: "gemini-2.0-flash",
  instruction: "Summarize the text.",
  output_key: :summary  # → stored in session state under :summary
)
```

---

## Events

### Inspect Events

```elixir
events = ADK.Runner.run(runner, user, session, msg)

# Get final text response
text =
  events
  |> Enum.reject(& &1.partial)
  |> Enum.filter(&(&1.author != "user"))
  |> Enum.flat_map(fn e ->
    case e.content do
      %{parts: parts} -> Enum.map(parts, & &1[:text] || "")
      _ -> []
    end
  end)
  |> Enum.join("")

# Or use Eval.Scorer helper
text = ADK.Eval.Scorer.response_text(events)
```

---

## LLM Backends

```elixir
# config/config.exs
config :adk, :llm_backend, ADK.LLM.Gemini
config :adk, :gemini_api_key, System.get_env("GEMINI_API_KEY")

# OpenAI
config :adk, :llm_backend, ADK.LLM.OpenAI
config :adk, :openai_api_key, System.get_env("OPENAI_API_KEY")

# Anthropic
config :adk, :llm_backend, ADK.LLM.Anthropic
config :adk, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")

# Test / no-op (default)
config :adk, :llm_backend, ADK.LLM.Mock
```

---

## Mix Tasks

```bash
mix adk.new my_app        # scaffold a new ADK project
mix test                  # run all tests
mix test --trace          # verbose test output
mix docs                  # generate ExDoc
mix format                # auto-format code
mix compile --warnings-as-errors  # strict compile check
```

---

## Remote A2A Agent

```elixir
alias ADK.Agent.RemoteA2aAgent

remote = RemoteA2aAgent.new(
  name: "remote_bot",
  agent_card_url: "https://mybot.example.com/.well-known/agent.json"
)

pipeline = SequentialAgent.new(
  name: "orchestrator",
  sub_agents: [local_agent, remote]
)
```
