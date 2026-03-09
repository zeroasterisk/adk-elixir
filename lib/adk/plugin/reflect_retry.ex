defmodule ADK.Plugin.ReflectRetry do
  @moduledoc """
  A plugin that validates LLM responses and retries with reflection feedback
  when they don't meet quality criteria.

  ## Configuration

      # Basic — retries on error events only (default behaviour)
      ADK.Plugin.register({ADK.Plugin.ReflectRetry, max_retries: 3})

      # With custom validation — retries when validator returns {:error, reason}
      ADK.Plugin.register({ADK.Plugin.ReflectRetry,
        max_retries: 3,
        validator: fn events ->
          text = events |> Enum.map_join("\\n", &ADK.Event.text/1)
          if String.contains?(text, "I don't know"),
            do: {:error, "Response was evasive — provide a concrete answer"},
            else: :ok
        end
      })

      # With custom reflection template
      ADK.Plugin.register({ADK.Plugin.ReflectRetry,
        max_retries: 2,
        validator: &MyApp.validate_response/1,
        reflection_template: "Attempt {attempt}/{max}: {reason}\\n\\nPlease revise your response."
      })

  ## How it works

  In `after_run/3`, this plugin:

  1. Checks for error events (events with non-nil `:error` field)
  2. If no errors and a `:validator` function is configured, calls it with the events
  3. If validation fails (or errors found), builds a reflection message and re-runs the agent
  4. Repeats up to `:max_retries` times
  5. Returns whatever the last attempt produced if retries are exhausted

  ## Validator function

  The validator receives the list of events and must return:
  - `:ok` — response is acceptable
  - `{:error, reason}` — response failed validation; `reason` is included in reflection

  ## Reflection template

  The template string supports these placeholders:
  - `{attempt}` — current attempt number (1-based)
  - `{max}` — max retries configured
  - `{reason}` — the error/validation failure reason

  Default: `"[Reflect & Retry — Attempt {attempt}/{max}] {reason}\\n\\nPlease try again, adjusting your approach."`
  """

  @behaviour ADK.Plugin

  @default_max_retries 3
  @default_template "[Reflect & Retry — Attempt {attempt}/{max}] {reason}\n\nPlease try again, adjusting your approach."

  @type validator :: ([ADK.Event.t()] -> :ok | {:error, String.t()})

  @type config :: [
          max_retries: pos_integer(),
          validator: validator() | nil,
          reflection_template: String.t()
        ]

  @type state :: %{
          max_retries: pos_integer(),
          validator: validator() | nil,
          reflection_template: String.t(),
          retry_counts: %{String.t() => non_neg_integer()}
        }

  @impl true
  def init(config) when is_list(config) do
    {:ok,
     %{
       max_retries: Keyword.get(config, :max_retries, @default_max_retries),
       validator: Keyword.get(config, :validator),
       reflection_template: Keyword.get(config, :reflection_template, @default_template),
       retry_counts: %{}
     }}
  end

  def init(config) when is_map(config) do
    {:ok,
     %{
       max_retries: Map.get(config, :max_retries, @default_max_retries),
       validator: Map.get(config, :validator),
       reflection_template: Map.get(config, :reflection_template, @default_template),
       retry_counts: %{}
     }}
  end

  def init(_), do: init([])

  @impl true
  def before_run(context, state) do
    {:cont, context, state}
  end

  @impl true
  def after_run(events, context, state) do
    invocation_id = (context.invocation_id || "unknown") <> ":reflect_retry"
    current_count = Map.get(state.retry_counts, invocation_id, 0)

    case check_events(events, state) do
      :ok ->
        {events, state}

      {:error, _reason} when current_count >= state.max_retries ->
        # Exhausted retries — return as-is
        {events, state}

      {:error, reason} ->
        attempt = current_count + 1
        new_state = put_in(state.retry_counts[invocation_id], attempt)

        reflection_text = format_template(state.reflection_template, attempt, state.max_retries, reason)
        reflection_event = build_reflection_event(reflection_text)

        # Re-run the agent with reflection context
        reflection_ctx = ADK.Context.put_temp(context, :reflection_feedback, reflection_text)
        retry_events = ADK.Agent.run(context.agent, reflection_ctx)

        # Recurse to check retry result (may need more retries)
        after_run(
          [reflection_event | retry_events],
          context,
          new_state
        )
    end
  end

  @doc "Check events for errors or validation failures."
  @spec check_events([ADK.Event.t()], state()) :: :ok | {:error, String.t()}
  def check_events(events, state) do
    # First check for error events
    error_events = Enum.filter(events, &has_error?/1)

    if error_events != [] do
      reason =
        error_events
        |> Enum.map(fn e -> e.error || "unknown error" end)
        |> Enum.join("; ")

      {:error, reason}
    else
      # Then run custom validator if configured
      case state.validator do
        nil -> :ok
        validator when is_function(validator, 1) -> validator.(events)
      end
    end
  end

  @doc "Check if an event has an error."
  @spec has_error?(ADK.Event.t()) :: boolean()
  def has_error?(%{error: err}) when not is_nil(err), do: true
  def has_error?(_), do: false

  @doc "Build reflection events from error events (legacy helper)."
  @spec build_reflection_events([ADK.Event.t()], pos_integer()) :: [ADK.Event.t()]
  def build_reflection_events(error_events, attempt) do
    reason =
      error_events
      |> Enum.map(fn e -> e.error || "unknown error" end)
      |> Enum.join("; ")

    [build_reflection_event(format_template(@default_template, attempt, @default_max_retries, reason))]
  end

  defp build_reflection_event(text) do
    ADK.Event.new(%{
      author: "system",
      content: %{parts: [%{text: text}]}
    })
  end

  defp format_template(template, attempt, max, reason) do
    template
    |> String.replace("{attempt}", to_string(attempt))
    |> String.replace("{max}", to_string(max))
    |> String.replace("{reason}", reason)
  end
end
