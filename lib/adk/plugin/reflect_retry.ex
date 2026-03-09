defmodule ADK.Plugin.ReflectRetry do
  @moduledoc """
  A plugin that intercepts failed tool calls or model errors and feeds
  the error back to the LLM with a "try again" prompt.

  Uses the existing Plugin + Callback system. Configurable max retries.

  ## Configuration

      ADK.Plugin.register({ADK.Plugin.ReflectRetry, max_retries: 3})

  ## How it works

  In `after_run/3`, this plugin inspects the result events. If any event
  has an `:error` field set, it:

  1. Increments the retry counter
  2. If under max_retries, creates a new reflection event with the error context
     and re-runs the agent
  3. If max_retries exceeded, passes through the error events as-is

  The reflection event includes the original error so the LLM can adjust its approach.
  """

  @behaviour ADK.Plugin

  @default_max_retries 3

  @type state :: %{
          max_retries: pos_integer(),
          retry_counts: %{String.t() => non_neg_integer()}
        }

  @impl true
  def init(config) when is_list(config) do
    {:ok, %{
      max_retries: Keyword.get(config, :max_retries, @default_max_retries),
      retry_counts: %{}
    }}
  end

  def init(config) when is_map(config) do
    {:ok, %{
      max_retries: Map.get(config, :max_retries, @default_max_retries),
      retry_counts: %{}
    }}
  end

  def init(_), do: {:ok, %{max_retries: @default_max_retries, retry_counts: %{}}}

  @impl true
  def before_run(context, state) do
    {:cont, context, state}
  end

  @impl true
  def after_run(events, context, state) do
    error_events = Enum.filter(events, &has_error?/1)

    if error_events == [] do
      {events, state}
    else
      invocation_id = context.invocation_id || "unknown"
      current_retries = Map.get(state.retry_counts, invocation_id, 0)

      if current_retries >= state.max_retries do
        # Max retries reached, pass through
        {events, state}
      else
        # Build reflection events and re-run
        new_state = %{state | retry_counts: Map.put(state.retry_counts, invocation_id, current_retries + 1)}

        reflection_events = build_reflection_events(error_events, current_retries + 1)

        # Try re-running the agent with reflection context
        reflection_ctx = inject_reflection(context, error_events)
        retry_events = ADK.Agent.run(context.agent, reflection_ctx)

        # Check if retry also failed
        retry_errors = Enum.filter(retry_events, &has_error?/1)

        if retry_errors == [] do
          # Success! Return reflection + successful events
          {reflection_events ++ retry_events, new_state}
        else
          # Still failing - recurse through after_run for more retries
          {all_events, final_state} = after_run(
            reflection_events ++ retry_events,
            context,
            new_state
          )
          {all_events, final_state}
        end
      end
    end
  end

  @doc """
  Check if an event represents an error.
  """
  @spec has_error?(ADK.Event.t()) :: boolean()
  def has_error?(%{error: err}) when not is_nil(err), do: true
  def has_error?(_), do: false

  @doc """
  Build reflection events that inform the LLM about what went wrong.
  """
  @spec build_reflection_events([ADK.Event.t()], pos_integer()) :: [ADK.Event.t()]
  def build_reflection_events(error_events, attempt) do
    error_summaries =
      error_events
      |> Enum.map(fn event ->
        error_text = event.error || "unknown error"
        author = event.author || "unknown"
        "Agent '#{author}' encountered an error: #{error_text}"
      end)
      |> Enum.join("\n")

    [
      ADK.Event.new(%{
        author: "system",
        content: %{
          parts: [
            %{text: "[Reflect & Retry - Attempt #{attempt}] Previous execution failed:\n#{error_summaries}\n\nPlease try again, adjusting your approach based on the error above."}
          ]
        }
      })
    ]
  end

  defp inject_reflection(context, error_events) do
    error_summary =
      error_events
      |> Enum.map(fn e -> e.error || "unknown error" end)
      |> Enum.join("; ")

    ADK.Context.put_temp(context, :last_error, error_summary)
  end
end
