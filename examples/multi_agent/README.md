# Multi-Agent Example

Demonstrates agent transfer in ADK — a router agent that delegates to specialist sub-agents.

## Architecture

```
Router Agent
├── Weather Agent (get_weather tool)
└── Math Agent (calculate tool)
```

The router agent decides which specialist to transfer to based on the user's query. Transfer is handled via `transfer_to_agent` tools that are automatically generated for each sub-agent.

## Running

```bash
cd examples/multi_agent
mix deps.get
mix test
```

## Usage

```elixir
# In iex -S mix:

# Weather query → transfers to weather agent
events = MultiAgent.chat("What's the weather in Tokyo?")
IO.inspect(events, label: "Events")

# Math query → transfers to math agent
events = MultiAgent.chat("What is 2 + 2?")

# Multi-turn conversation
events = MultiAgent.chat("Weather in NYC?", session_id: "s1")
events = MultiAgent.chat("Now what about London?", session_id: "s1")
```

## How Transfer Works

1. The router agent's tool list includes `transfer_to_agent_weather` and `transfer_to_agent_math`
2. When the LLM calls one of these tools, it produces a transfer event
3. The parent agent detects the transfer and delegates execution to the target sub-agent
4. The sub-agent runs with its own tools and instruction, returning events back up

This mirrors Google ADK Python's `transfer_to_agent` pattern.
