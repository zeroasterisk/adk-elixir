# ADK Web Compatibility Layer

This guide explains how to use ADK Elixir as a drop-in backend replacement for the [adk-web](https://github.com/google/adk-web) React frontend.

## Overview

The `ADK.Phoenix.WebRouter` module provides HTTP endpoints that match the Python ADK's `adk web` FastAPI server exactly, enabling the adk-web frontend to work with an Elixir backend without modification.

## Quick Start

### 1. Add Dependencies

Ensure your `mix.exs` includes:

```elixir
{:adk, path: "../adk-elixir"},  # or from hex
{:plug, "~> 1.14"},
{:jason, "~> 1.4"},
{:bandit, "~> 1.0"},  # or {:plug_cowboy, "~> 2.5"}
```

### 2. Define Your Agents

Create an agent loader — either a map or a module:

```elixir
# Simple map-based loader
agents = %{
  "my_agent" => ADK.Agent.LlmAgent.new(
    name: "assistant",
    model: "gemini-2.0-flash",
    instruction: "You are a helpful assistant."
  )
}

# Or a module-based loader
defmodule MyApp.AgentLoader do
  def list_agents, do: ["my_agent"]

  def list_agents_detailed do
    [%{
      name: "my_agent",
      root_agent_name: "assistant",
      description: "A helpful assistant",
      language: "elixir",
      is_computer_use: false
    }]
  end

  def load_agent("my_agent") do
    ADK.Agent.LlmAgent.new(
      name: "assistant",
      model: "gemini-2.0-flash",
      instruction: "You are a helpful assistant."
    )
  end

  def load_agent(_), do: nil
end
```

### 3. Start the Server

```elixir
# Standalone with Bandit
opts = [
  agent_loader: agents,  # or MyApp.AgentLoader
  session_store: {ADK.Session.Store.InMemory, []}
]

Bandit.start_link(
  plug: {ADK.Phoenix.WebRouter, opts},
  port: 8000
)
```

Or in a Phoenix router:

```elixir
# In your router.ex
forward "/api", ADK.Phoenix.WebRouter,
  agent_loader: MyApp.AgentLoader,
  session_store: {ADK.Session.Store.InMemory, []}
```

### 4. Connect adk-web Frontend

Point the adk-web frontend at your Elixir server:

```bash
# Clone adk-web
git clone https://github.com/google/adk-web
cd adk-web

# Set the backend URL
echo "VITE_API_URL=http://localhost:8000" > .env.local

# Start the frontend
npm install && npm run dev
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `GET` | `/version` | Version info |
| `GET` | `/list-apps` | List available agents |
| `GET` | `/apps/:app/users/:user/sessions` | List sessions |
| `POST` | `/apps/:app/users/:user/sessions` | Create session |
| `GET` | `/apps/:app/users/:user/sessions/:id` | Get session |
| `DELETE` | `/apps/:app/users/:user/sessions/:id` | Delete session |
| `POST` | `/run` | Run agent (JSON response) |
| `POST` | `/run_sse` | Run agent (SSE streaming) |

## Request/Response Shapes

All shapes match the Python ADK exactly. See the test file at `test/adk/phoenix/web_router_test.exs` for examples.

### POST /run_sse

Request body:

```json
{
  "app_name": "my_agent",
  "user_id": "user123",
  "session_id": "sess456",
  "new_message": {
    "parts": [{"text": "Hello!"}]
  },
  "streaming": false
}
```

Response: SSE stream with `data: {event_json}\n\n` lines.

### POST /apps/:app/users/:user/sessions

Request body:

```json
{
  "session_id": "optional-custom-id",
  "state": {"key": "value"}
}
```

## CORS

CORS headers (`Access-Control-Allow-Origin: *`) are included on all responses by default. The `OPTIONS` preflight is handled automatically.

## Session Persistence

By default, sessions use `ADK.Session.Store.InMemory` (ETS-backed). For production, use `ADK.Session.Store.Ecto` with a database backend.
