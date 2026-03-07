defmodule ADK.Runner.Async do
  @moduledoc """
  Runs an agent asynchronously in a separate process, sending events
  back to the caller as `{:adk_event, event}` messages.

  This is a pure BEAM module — no Phoenix dependency required.

  ## Example

      {:ok, pid} = ADK.Runner.Async.run(runner, "user1", "sess1", "Hello!")
      # Receive events in your process:
      receive do
        {:adk_event, event} -> IO.inspect(event)
      end
      # When done, you'll get:
      receive do
        {:adk_done, events} -> IO.puts("Got \#{length(events)} events")
      end
  """

  @doc """
  Run an agent asynchronously. Returns `{:ok, pid}`.

  Events are sent to `opts[:reply_to]` (default: `self()`):
  - `{:adk_event, event}` for each event
  - `{:adk_done, events}` when complete
  - `{:adk_error, reason}` on failure
  """
  @spec run(ADK.Runner.t(), String.t(), String.t(), map() | String.t(), keyword()) ::
          {:ok, pid()}
  def run(%ADK.Runner{} = runner, user_id, session_id, message, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to, self())
    runner_opts = Keyword.get(opts, :runner_opts, [])

    pid =
      spawn_link(fn ->
        try do
          events = ADK.Runner.run(runner, user_id, session_id, message, runner_opts)

          Enum.each(events, fn event ->
            send(reply_to, {:adk_event, event})
          end)

          send(reply_to, {:adk_done, events})
        rescue
          e ->
            send(reply_to, {:adk_error, {e, __STACKTRACE__}})
        end
      end)

    {:ok, pid}
  end

  @doc """
  Like `run/5` but uses `Task` for better supervision integration.
  Returns a `Task` struct.
  """
  @spec run_task(ADK.Runner.t(), String.t(), String.t(), map() | String.t(), keyword()) ::
          Task.t()
  def run_task(%ADK.Runner{} = runner, user_id, session_id, message, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to, self())
    runner_opts = Keyword.get(opts, :runner_opts, [])

    Task.async(fn ->
      events = ADK.Runner.run(runner, user_id, session_id, message, runner_opts)

      Enum.each(events, fn event ->
        send(reply_to, {:adk_event, event})
      end)

      events
    end)
  end
end
