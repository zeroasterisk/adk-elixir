# Weather Agent Example

A simple weather lookup agent built with [ADK Elixir](https://github.com/zeroasterisk/adk-elixir).

## What it demonstrates

- **Agent definition** — Creating an `LlmAgent` with a system instruction
- **Tool creation** — Building a `FunctionTool` for weather lookups
- **Runner usage** — Using `ADK.Runner` to execute agent conversations
- **Multi-turn conversation** — Interactive CLI chat loop

## Setup

```bash
mix deps.get
```

## Usage

### Single query

```elixir
iex -S mix

iex> WeatherAgent.chat("What's the weather in Tokyo?")
```

### Interactive mode

```elixir
iex> WeatherAgent.interactive()
```

### Running tests

```bash
mix test
```

## Configuration

Set `ADK_MODEL` environment variable to change the LLM model (default: `gemini-flash-latest`).

```bash
ADK_MODEL=claude-sonnet-4-20250514 iex -S mix
```

## Project Structure

```
lib/
  weather_agent.ex          # Main agent module
  weather_agent/tools.ex    # Weather tool definitions
test/
  weather_agent_test.exs    # Agent tests
  weather_agent/tools_test.exs  # Tool tests
```

## Notes

The weather data is simulated. In a real application, replace `WeatherAgent.Tools.get_weather/1`
with a call to a weather API like OpenWeatherMap or WeatherAPI.
