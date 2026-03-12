# mix adk.new — Project Generator

`mix adk.new` scaffolds a new ADK agent project, ready to compile and run.

## Quick Start

```bash
mix adk.new my_agent
cd my_agent
export GEMINI_API_KEY=your_key
mix deps.get
iex -S mix
```

```elixir
iex> MyAgent.Agent.run("Hello!")
```

## Usage

```
mix adk.new NAME [--path DIR] [--model MODEL] [--no-phoenix]
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--path` | `.` | Parent directory for the project |
| `--model` | `gemini-flash-latest` | Default LLM model |
| `--no-phoenix` | (included) | Skip web router and Bandit dependency |

### Examples

```bash
# Basic agent
mix adk.new my_agent

# Custom model, no web server
mix adk.new my_agent --model gemini-2.5-pro --no-phoenix

# Create in a specific directory
mix adk.new my_agent --path ~/projects
```

## What Gets Generated

```
my_agent/
├── mix.exs                    # Project config with ADK dependency
├── lib/
│   ├── my_agent.ex            # Root module
│   └── my_agent/
│       ├── agent.ex           # LlmAgent with system instruction + tools
│       ├── tools.ex           # Sample FunctionTools (greet, calculate)
│       ├── application.ex     # OTP supervision tree
│       └── router.ex          # ADK Web endpoints (unless --no-phoenix)
├── config/
│   ├── config.exs             # Model + API key config
│   ├── dev.exs                # Dev settings
│   └── test.exs               # Mock LLM for tests
├── test/
│   ├── test_helper.exs
│   └── my_agent/
│       └── agent_test.exs     # Tool + agent tests
├── README.md
├── .gitignore
└── .formatter.exs
```

## Generated Agent

The scaffolded agent is a pirate-themed assistant with two tools:

- **greet** — Pirate-style greeting by name
- **calculate** — Basic arithmetic (`2 + 3`, `10 / 2`)

This is meant as a starting point. Replace the instruction, tools, and model to build your own agent.

## Web Server

When generated with Phoenix support (default), the project includes a router module that exposes the ADK Web API:

```elixir
# In iex:
MyAgent.Router.start(port: 8080)
```

This serves the same REST API as Python ADK's `adk web`, so the [adk-web](https://github.com/google/adk-web) React frontend works as a drop-in UI.

### Endpoints

- `GET /health` — Health check
- `GET /list-apps` — List available agents
- `POST /run` — Run agent synchronously
- `POST /run_sse` — Run agent with SSE streaming
- Session CRUD under `/apps/:app/users/:user/sessions`

## Customizing

### Change the model

Edit `config/config.exs`:

```elixir
config :my_agent, model: "gemini-2.5-pro"
```

### Add tools

Define new tools in `lib/my_agent/tools.ex` and add them to the agent's tools list in `lib/my_agent/agent.ex`.

### Add sub-agents

```elixir
ADK.Agent.LlmAgent.new(
  name: "my_agent",
  model: model,
  instruction: "...",
  tools: [...],
  sub_agents: [MyAgent.SubAgent.build()]
)
```

### Use a different LLM provider

```elixir
# config/config.exs
config :my_agent, model: "gpt-4o"

config :adk,
  openai_api_key: System.get_env("OPENAI_API_KEY")
```
