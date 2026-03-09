# ReflectRetry Plugin Example

The `ADK.Plugin.ReflectRetry` plugin automatically retries LLM responses that fail validation, injecting reflection feedback so the model can self-correct.

## Usage

### Basic: Retry on errors

```elixir
# Retries up to 3 times when any event has an error
ADK.Plugin.register({ADK.Plugin.ReflectRetry, max_retries: 3})
```

### Custom validation

```elixir
# Retry when the response doesn't contain valid JSON
json_validator = fn events ->
  text = events |> Enum.map_join("", &(ADK.Event.text(&1) || ""))
  case Jason.decode(text) do
    {:ok, _} -> :ok
    {:error, _} -> {:error, "Response must be valid JSON. Output ONLY a JSON object."}
  end
end

ADK.Plugin.register({ADK.Plugin.ReflectRetry,
  max_retries: 3,
  validator: json_validator
})
```

### Quality gate

```elixir
# Ensure responses are substantive
ADK.Plugin.register({ADK.Plugin.ReflectRetry,
  max_retries: 2,
  validator: fn events ->
    text = events |> Enum.map_join(" ", &(ADK.Event.text(&1) || ""))
    cond do
      String.length(text) < 50 ->
        {:error, "Response too short — provide a detailed answer"}
      String.contains?(text, "I don't know") ->
        {:error, "Don't say 'I don't know' — provide your best answer with caveats"}
      true ->
        :ok
    end
  end,
  reflection_template: "[Quality Check - Attempt {attempt}/{max}] {reason}\n\nRevise your response to meet the quality criteria."
})
```

## How it works

1. After the agent runs, `after_run/3` checks the response events
2. First checks for error events (events with non-nil `:error` field)  
3. Then runs the custom `validator` function if configured
4. On failure: injects a reflection event with feedback and re-runs the agent
5. The reflection feedback is also available via `ADK.Context.get_temp(ctx, :reflection_feedback)`
6. Repeats up to `max_retries` times
7. Returns whatever the last attempt produced if retries exhausted

## Configuration options

| Option | Default | Description |
|--------|---------|-------------|
| `:max_retries` | 3 | Maximum retry attempts |
| `:validator` | nil | `fn events -> :ok \| {:error, reason}` |
| `:reflection_template` | (built-in) | Template with `{attempt}`, `{max}`, `{reason}` placeholders |
