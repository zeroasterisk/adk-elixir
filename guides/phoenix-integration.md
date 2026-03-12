# Phoenix Integration Guide

ADK Elixir provides optional helpers for integrating agents into Phoenix applications. ADK itself has **no Phoenix dependency** — these modules use Phoenix only when it's available in your project.

## Overview

There are three integration patterns:

| Pattern | Module | Best For |
|---------|--------|----------|
| REST API | `ADK.Phoenix.Controller` | Simple request/response, external clients |
| WebSocket | `ADK.Phoenix.Channel` | Real-time bidirectional, JS clients |
| LiveView | `ADK.Phoenix.LiveHandler` | Server-rendered UI, real-time updates |

All three rely on `ADK.Runner.Async` — a pure OTP module that runs agents in background processes and sends events as messages.

## Setup

Add ADK to your Phoenix project's `mix.exs`:

```elixir
defp deps do
  [
    {:phoenix, "~> 1.7"},
    {:adk, github: "zeroasterisk/adk-elixir"},
    # ... other deps
  ]
end
```

Define your agent somewhere in your app:

```elixir
defmodule MyApp.Agents do
  def assistant do
    ADK.new("assistant",
      model: "gemini-flash-latest",
      instruction: "You are a helpful assistant."
    )
  end
end
```

## Pattern 1: REST API (Controller)

The simplest integration — a controller that runs an agent and returns JSON.

### Router

```elixir
# lib/my_app_web/router.ex
scope "/api", MyAppWeb do
  pipe_through :api
  post "/agent/run", AgentController, :run
  post "/agent/stream", AgentController, :stream
end
```

### Controller

```elixir
defmodule MyAppWeb.AgentController do
  use MyAppWeb, :controller

  def run(conn, params) do
    runner = %ADK.Runner{app_name: "my_app", agent: MyApp.Agents.assistant()}
    ADK.Phoenix.Controller.run(conn, runner, params)
  end

  def stream(conn, params) do
    runner = %ADK.Runner{app_name: "my_app", agent: MyApp.Agents.assistant()}
    ADK.Phoenix.Controller.stream_sse(conn, runner, params)
  end
end
```

### Client Usage

```bash
# Synchronous
curl -X POST http://localhost:4000/api/agent/run \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello!", "user_id": "user1", "session_id": "sess1"}'

# SSE Streaming
curl -X POST http://localhost:4000/api/agent/stream \
  -H "Content-Type: application/json" \
  -d '{"message": "Tell me a story", "user_id": "user1", "session_id": "sess1"}'
```

## Pattern 2: WebSocket (Channel)

Real-time bidirectional communication via Phoenix Channels.

### Channel

```elixir
defmodule MyAppWeb.AgentChannel do
  use MyAppWeb, :channel
  use ADK.Phoenix.Channel, agent: &MyApp.Agents.assistant/0

  # Optional: customize user/session resolution
  defp adk_user_id(socket), do: socket.assigns.user_id
  defp adk_session_id(socket), do: socket.assigns.session_id

  def join("agent:lobby", _params, socket) do
    {:ok, socket}
  end
end
```

### Socket

```elixir
# lib/my_app_web/channels/user_socket.ex
defmodule MyAppWeb.UserSocket do
  use Phoenix.Socket

  channel "agent:*", MyAppWeb.AgentChannel

  def connect(%{"user_id" => user_id}, socket, _connect_info) do
    {:ok, assign(socket, :user_id, user_id)}
  end

  def id(socket), do: "user:#{socket.assigns.user_id}"
end
```

### JavaScript Client

```javascript
import { Socket } from "phoenix"

const socket = new Socket("/socket", { params: { user_id: "user1" } })
socket.connect()

const channel = socket.channel("agent:lobby", {})
channel.join()

// Synchronous run
channel.push("agent:run", { message: "Hello!" })
  .receive("ok", ({ events }) => {
    events.forEach(e => console.log(e.content))
  })

// Streaming
channel.push("agent:stream", { message: "Tell me a story" })
channel.on("agent:event", event => {
  console.log("Event:", event.content)
})
channel.on("agent:done", ({ event_count }) => {
  console.log(`Done! ${event_count} events`)
})
```

## Pattern 3: LiveView

Server-rendered real-time UI — the most Elixir-native approach.

### LiveView

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view
  use ADK.Phoenix.LiveHandler, agent: &MyApp.Agents.assistant/0

  def mount(_params, session, socket) do
    {:ok, assign(socket,
      messages: [],
      input: "",
      loading: false,
      user_id: session["user_id"] || "anonymous",
      session_id: "live-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64()}"
    )}
  end

  def handle_event("send", %{"message" => msg}, socket) when msg != "" do
    # Add user message to UI
    messages = socket.assigns.messages ++ [%{role: "user", text: msg}]
    socket = assign(socket, messages: messages, input: "", loading: true)

    # Run agent async — events come back via handle_info
    socket = adk_run_async(socket, msg)
    {:noreply, socket}
  end

  def handle_event("update_input", %{"message" => msg}, socket) do
    {:noreply, assign(socket, input: msg)}
  end

  # Override to customize event handling
  def handle_adk_event(event, socket) do
    if ADK.Event.text?(event) do
      msg = %{role: "agent", text: ADK.Event.text(event)}
      messages = socket.assigns.messages ++ [msg]
      {:noreply, assign(socket, messages: messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_adk_done(_events, socket) do
    {:noreply, assign(socket, loading: false)}
  end

  def render(assigns) do
    ~H"""
    <div class="chat-container">
      <div class="messages">
        <%= for msg <- @messages do %>
          <div class={"message #{msg.role}"}>
            <strong><%= msg.role %>:</strong> <%= msg.text %>
          </div>
        <% end %>
        <%= if @loading do %>
          <div class="message loading">Thinking...</div>
        <% end %>
      </div>

      <form phx-submit="send">
        <input type="text" name="message" value={@input}
               phx-change="update_input" placeholder="Type a message..."
               disabled={@loading} />
        <button type="submit" disabled={@loading}>Send</button>
      </form>
    </div>
    """
  end
end
```

### Router

```elixir
live "/chat", ChatLive
```

## Session Management

For persistent conversations across requests, use a session store:

```elixir
# Use the JSON file store for persistence
runner = %ADK.Runner{
  app_name: "my_app",
  agent: MyApp.Agents.assistant(),
  session_store: ADK.Session.Store.JsonFile
}
```

Use consistent `user_id` and `session_id` values across requests to maintain conversation history.

## The Async Runner

`ADK.Runner.Async` is the foundation. It's a pure BEAM module — no Phoenix needed:

```elixir
# Run agent in background, get events as messages
{:ok, pid} = ADK.Runner.Async.run(runner, user_id, session_id, message)

# In any GenServer/Channel/LiveView handle_info:
def handle_info({:adk_event, event}, state) do
  # Process each event as it arrives
end

def handle_info({:adk_done, all_events}, state) do
  # All events collected
end

def handle_info({:adk_error, reason}, state) do
  # Handle errors
end
```

You can use this directly in any OTP process — GenServer, Task, or custom process — without any Phoenix modules at all.

## Event Serialization

Events can be serialized to/from JSON-friendly maps:

```elixir
# To JSON
json = event |> ADK.Event.to_map() |> Jason.encode!()

# From JSON
event = json |> Jason.decode!() |> ADK.Event.from_map()
```

This is used internally by the Phoenix helpers but is available for any custom integration.
