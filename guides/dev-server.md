# ADK Dev Server

The `mix adk.server` task launches a local web server with a browser-based chat UI,
letting you interact with your agent during development — similar to Python ADK's `adk web`.

## Quick Start

```bash
mix adk.server
# => ADK Dev Server running at http://localhost:4000
```

Open [http://localhost:4000](http://localhost:4000) in your browser to chat with a demo agent.

## Options

| Flag | Default | Description |
|---|---|---|
| `--port` | `4000` | HTTP port to listen on |
| `--agent` | *(demo)* | Agent module name (e.g. `MyApp.MyAgent`) |
| `--model` | `gemini-flash-latest` | LLM model to use |

## Examples

```bash
# Default demo agent
mix adk.server

# Your custom agent
mix adk.server --agent MyApp.Agent

# Different port and model
mix adk.server --port 8080 --agent MyApp.Agent --model gemini-2.5-pro
```

## API Endpoints

The dev server exposes a simple REST API:

### `GET /`

Returns the HTML chat UI. Open this in your browser.

### `GET /api/agent`

Returns agent info as JSON:

```json
{
  "name": "MyApp.Agent",
  "module": "Elixir.MyApp.Agent",
  "model": "gemini-flash-latest"
}
```

### `POST /api/chat`

Send a message to the agent:

```bash
curl -X POST http://localhost:4000/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello!"}'
```

Response:

```json
{
  "response": "Hello! How can I help you today?",
  "session_id": "dev-abc123",
  "events": [...]
}
```

You can pass `session_id` to continue a conversation:

```bash
curl -X POST http://localhost:4000/api/chat \
  -d '{"message": "Follow-up question", "session_id": "dev-abc123"}'
```

## Chat UI Features

- Send messages with Enter (Shift+Enter for newline)
- See agent responses with markdown-like formatting
- Tool calls are shown inline (function name highlighted)
- Session ID persists across messages in the same browser tab
- Dark theme, minimal deps — no build step required

## Custom Agent Modules

When you pass `--agent MyApp.MyAgent`, the dev server will attempt to load your agent using:

1. `MyApp.MyAgent.agent/0` — if you have a factory function
2. `MyApp.MyAgent.new/0` — if you have a `new/0` constructor
3. `struct(MyApp.MyAgent)` — direct struct instantiation

The simplest approach is to implement `agent/0`:

```elixir
defmodule MyApp.MyAgent do
  def agent do
    %ADK.Agent.LlmAgent{
      name: "my_agent",
      model: "gemini-flash-latest",
      instruction: "You are a helpful assistant.",
      tools: [MyApp.Tools.WeatherTool]
    }
  end
end
```

Then run:

```bash
mix adk.server --agent MyApp.MyAgent
```

## Dependencies

The dev server requires `bandit` (for HTTP serving) and `plug` (for routing).
These are optional deps — add them to your `mix.exs` if you get compile errors:

```elixir
{:plug, "~> 1.14"},
{:bandit, "~> 1.5"}
```

If you used `mix adk.new`, these are already included.

## Comparison with Python ADK

| Feature | `mix adk.server` | `adk web` (Python) |
|---|---|---|
| Browser chat UI | ✅ | ✅ |
| Custom agent | ✅ | ✅ |
| Custom port | ✅ | ✅ |
| Tool call display | ✅ | ✅ |
| Session persistence | In-memory | In-memory |
| Streaming | ❌ (planned) | ✅ SSE |
| React frontend | ❌ | ✅ |
| Multi-agent routing | ❌ | ✅ |
