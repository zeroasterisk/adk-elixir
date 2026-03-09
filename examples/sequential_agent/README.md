# Sequential Agent Example

A **content creation pipeline** using `ADK.Agent.SequentialAgent` to chain three agents:

```
Researcher → Writer → Editor
```

Each agent's output feeds into the next, creating a simple workflow pipeline.

## What This Demonstrates

- `ADK.Agent.SequentialAgent` for multi-step pipelines
- Agents with different personas/instructions collaborating
- Output flowing through a chain without explicit wiring
- Separation of concerns (research vs writing vs editing)

## Setup

```bash
cd examples/sequential_agent
mix deps.get
```

Set your API key:

```bash
export GOOGLE_API_KEY=your-key-here
```

## Usage

```elixir
iex -S mix

# Run the full pipeline
SequentialAgentExample.run("The future of Elixir in AI")

# Try different topics
SequentialAgentExample.run("Why functional programming matters in 2025")
SequentialAgentExample.run("Building resilient distributed systems")
```

## Pipeline Stages

| Stage | Agent | Role |
|-------|-------|------|
| 1 | `researcher` | Produces 5-7 bullet points of key facts |
| 2 | `writer` | Drafts a 3-4 paragraph blog post |
| 3 | `editor` | Polishes grammar, tone, and clarity |

## Project Structure

```
sequential_agent/
├── lib/
│   └── sequential_agent.ex   # Pipeline definition and runner
├── mix.exs
└── README.md
```
