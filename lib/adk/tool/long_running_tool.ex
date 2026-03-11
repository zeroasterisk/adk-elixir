defmodule ADK.Tool.LongRunningTool do
  @moduledoc """
  An asynchronous tool that executes work in a supervised BEAM process.

  Long-running tools spawn a Task under the `ADK.RunnerSupervisor`,
  allowing the tool function to send intermediate status updates while
  the caller awaits completion. This is the BEAM-idiomatic equivalent
  of Python ADK's `LongRunningFunctionTool`.

  ## Key differences from Python ADK

  Python ADK marks tools with `is_long_running = True` and relies on
  async/await coroutines. In Elixir, we use OTP processes:

  - Work runs in a supervised `Task` (fault-tolerant, isolated)
  - Status updates flow via process messages
  - Timeout is enforced via `receive...after`
  - Crashes in the tool are caught and returned as `{:error, reason}`

  ## Usage

      tool = ADK.Tool.LongRunningTool.new(:fetch_report,
        description: "Fetch and process a large report",
        func: fn _ctx, %{"url" => url}, send_update ->
          send_update.("Connecting to \#{url}...")
          data = fetch_data(url)
          send_update.("Processing \#{byte_size(data)} bytes...")
          process(data)
        end,
        parameters: %{
          type: "object",
          properties: %{url: %{type: "string", description: "Report URL"}},
          required: ["url"]
        },
        timeout: 30_000
      )

  ## Function signature

  The `func` must accept 3 arguments:

  1. `tool_ctx` — `ADK.ToolContext.t()` (same as regular tools)
  2. `args` — `map()` of tool arguments from the LLM
  3. `send_update` — `(String.t() -> :ok)` callback to emit status updates

  ## Return value

  - `{:ok, result}` — success with final result
  - `{:ok, %{result: result, status_updates: [String.t()]}}` — success with updates captured
  - `{:error, reason}` — tool error, timeout, or crash

  ## Description annotation

  The tool description is automatically annotated with a note telling
  the LLM not to call the tool again if it has already returned a
  pending/intermediate status (matching Python ADK's behavior).
  """

  @type update_fn :: (String.t() -> :ok)
  @type tool_func :: (ADK.ToolContext.t(), map(), update_fn -> term())

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          func: tool_func(),
          parameters: map(),
          timeout: pos_integer()
        }

  defstruct [:name, :description, :func, :parameters, timeout: 60_000]

  @long_running_notice "\n\nNOTE: This is a long-running operation. Do not call this tool again if it has already returned some intermediate or pending status."

  @doc """
  Create a new long-running tool.

  ## Options

  - `:description` — Human-readable description (automatically annotated with long-running notice)
  - `:func` — The tool function `(tool_ctx, args, send_update) -> result`
  - `:parameters` — JSON Schema map for parameters
  - `:timeout` — Milliseconds to wait before timing out (default: 60_000)

  ## Examples

      iex> tool = ADK.Tool.LongRunningTool.new(:slow_tool,
      ...>   description: "Does slow work",
      ...>   func: fn _ctx, _args, _send_update -> "done" end,
      ...>   parameters: %{type: "object", properties: %{}}
      ...> )
      iex> tool.name
      "slow_tool"
      iex> String.contains?(tool.description, "long-running operation")
      true
  """
  @spec new(atom() | String.t(), keyword()) :: t()
  def new(name, opts) do
    description = build_description(opts[:description] || "")

    %__MODULE__{
      name: to_string(name),
      description: description,
      func: opts[:func],
      parameters: opts[:parameters] || %{},
      timeout: opts[:timeout] || 60_000
    }
  end

  @doc """
  Execute the long-running tool asynchronously.

  Spawns a supervised Task under `ADK.RunnerSupervisor`, collects
  any status updates the function sends, and awaits the final result
  within the configured timeout.

  Status updates from `send_update.(msg)` are collected in order.
  If any updates were sent, the result is wrapped:
  `{:ok, %{result: final_value, status_updates: ["update 1", ...]}}`.
  If no updates were sent, returns `{:ok, final_value}` directly.

  ## Examples

      iex> tool = ADK.Tool.LongRunningTool.new(:fast_tool,
      ...>   func: fn _ctx, %{"x" => x}, _send_update -> x * 2 end,
      ...>   parameters: %{},
      ...>   timeout: 5_000
      ...> )
      iex> {:ok, result} = ADK.Tool.LongRunningTool.run(tool, nil, %{"x" => 21})
      iex> result
      42
  """
  @spec run(t(), ADK.ToolContext.t() | nil, map()) :: ADK.Tool.result()
  def run(%__MODULE__{} = tool, tool_ctx, args) do
    caller = self()
    ref = make_ref()

    send_update_fn = fn status ->
      send(caller, {:long_running_update, ref, to_string(status)})
      :ok
    end

    # Start a supervised task — isolated from the caller (not linked)
    {:ok, task_pid} =
      Task.Supervisor.start_child(
        ADK.RunnerSupervisor,
        fn ->
          try do
            result = tool.func.(tool_ctx, args, send_update_fn)
            send(caller, {:long_running_complete, ref, {:ok, result}})
          rescue
            e ->
              reason = Exception.message(e)
              send(caller, {:long_running_complete, ref, {:error, reason}})
          catch
            :exit, reason ->
              err = "Tool process exited: #{inspect(reason)}"
              send(caller, {:long_running_complete, ref, {:error, err}})
          end
        end
      )

    monitor_ref = Process.monitor(task_pid)
    result = await_result(ref, monitor_ref, task_pid, tool.name, tool.timeout, [])
    Process.demonitor(monitor_ref, [:flush])
    result
  end

  # --- Private helpers ---

  defp await_result(ref, monitor_ref, task_pid, tool_name, timeout, updates) do
    receive do
      {:long_running_complete, ^ref, {:ok, val}} ->
        wrap_result(val, updates)

      {:long_running_complete, ^ref, {:error, _} = err} ->
        err

      {:long_running_update, ^ref, status} ->
        await_result(ref, monitor_ref, task_pid, tool_name, timeout, [status | updates])

      {:DOWN, ^monitor_ref, :process, ^task_pid, :normal} ->
        # Task finished normally but didn't send a complete message — shouldn't happen
        # but handle gracefully
        {:error, "Tool '#{tool_name}' process exited without result"}

      {:DOWN, ^monitor_ref, :process, ^task_pid, reason} ->
        {:error, "Tool '#{tool_name}' crashed: #{inspect(reason)}"}
    after
      timeout ->
        Process.exit(task_pid, :kill)
        {:error, "Tool '#{tool_name}' timed out after #{timeout}ms"}
    end
  end

  defp wrap_result(val, []) do
    {:ok, val}
  end

  defp wrap_result(val, updates) do
    {:ok, %{result: val, status_updates: Enum.reverse(updates)}}
  end

  defp build_description(""), do: String.trim_leading(@long_running_notice)
  defp build_description(desc), do: desc <> @long_running_notice
end
