# Getting Started

## Installation

Add `adk` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:adk, github: "zeroasterisk/adk-elixir"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Your First Agent

Create a simple agent that responds to messages:

```elixir
agent = ADK.new("greeter",
  model: "gemini-flash-latest",
  instruction: "You are a friendly greeter. Keep responses short and warm."
)

response = ADK.chat(agent, "Hi there!")
IO.puts(response)
```

## Adding Tools

Agents become powerful when they can use tools. Any function works:

```elixir
defmodule MyTools do
  def get_time(_args) do
    %{time: DateTime.utc_now() |> to_string()}
  end

  def get_weather(%{"city" => city}) do
    # In production, call a real API
    %{city: city, temp: 72, condition: "sunny"}
  end
end

agent = ADK.new("assistant",
  model: "gemini-flash-latest",
  instruction: "You help users with time and weather questions.",
  tools: [&MyTools.get_time/1, &MyTools.get_weather/1]
)

ADK.chat(agent, "What's the weather in Louisville?")
```

## Sequential Pipelines

Chain agents together — each agent's output becomes the next agent's input:

```elixir
researcher = ADK.new("researcher",
  instruction: "Find key facts about the topic. Be thorough."
)

writer = ADK.new("writer",
  instruction: "Write a concise, engaging summary from the research provided."
)

pipeline = ADK.sequential([researcher, writer], name: "research_pipeline")

ADK.chat(pipeline, "The history of Erlang")
```

## Working with Events

For full control, use `ADK.run/3` instead of `ADK.chat/3`:

```elixir
events = ADK.run(agent, "Hello!")

for event <- events do
  case event do
    %{author: "assistant"} ->
      IO.puts("Agent said: #{ADK.Event.text(event)}")

    %{actions: %{state_delta: delta}} when map_size(delta) > 0 ->
      IO.inspect(delta, label: "State changed")

    _ ->
      :ok
  end
end
```

## Next Steps

- Read the [Concepts guide](concepts.md) for architecture details
- Browse the [API docs](ADK.html) for full reference
- Check the [test suite](https://github.com/zeroasterisk/adk-elixir/tree/main/test) for more examples
