defmodule ADK.Runner.Async do
  @moduledoc """
  Runs an agent asynchronously under `ADK.RunnerSupervisor` (Task.Supervisor),
  sending events back to the caller as `{:adk_event, event}` messages.

  All async runs are supervised — if a runner crashes, it won't bring down
  the caller, and the supervisor tracks active tasks.

  ## Example

      {:ok, pid} = ADK.Runner.Async.run(runner, "user1", "sess1", "Hello!")
      receive do
        {:adk_event, event} -> IO.inspect(event)
      end
      receive do
        {:adk_done, events} -> IO.puts("Got \#{length(events)} events")
      end
  """

  @doc """
  Run an agent asynchronously under `ADK.RunnerSupervisor`.

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
    supervisor = Keyword.get(opts, :supervisor, ADK.RunnerSupervisor)

    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, fn ->
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
  Like `run/5` but returns a `Task` struct for awaiting the result.

  Uses `Task.Supervisor.async_nolink/2` so the caller isn't linked to the task.
  """
  @spec run_task(ADK.Runner.t(), String.t(), String.t(), map() | String.t(), keyword()) ::
          Task.t()
  def run_task(%ADK.Runner{} = runner, user_id, session_id, message, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to, self())
    runner_opts = Keyword.get(opts, :runner_opts, [])
    supervisor = Keyword.get(opts, :supervisor, ADK.RunnerSupervisor)

    Task.Supervisor.async_nolink(supervisor, fn ->
      events = ADK.Runner.run(runner, user_id, session_id, message, runner_opts)

      Enum.each(events, fn event ->
        send(reply_to, {:adk_event, event})
      end)

      events
    end)
  end
end
