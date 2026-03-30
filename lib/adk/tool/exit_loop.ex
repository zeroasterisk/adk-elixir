defmodule ADK.Tool.ExitLoop do
  @moduledoc """
  Built-in tool that allows an LLM inside a `LoopAgent` to break out of the loop.

  When called, the tool returns `{:exit_loop, reason}`, which `LlmAgent`
  detects and converts to an event with `actions.escalate = true`. The
  `LoopAgent` sees the escalate flag and stops iterating.

  This mirrors Python ADK's escalation mechanism where an agent inside a
  `LoopAgent` can signal that the task is complete and the loop should exit.

  ## Usage

  Add the exit_loop tool to any `LlmAgent` that runs inside a `LoopAgent`:

      agent = ADK.Agent.LlmAgent.new(
        name: "worker",
        model: "gemini-flash-latest",
        instruction: "Do the task. When finished, call exit_loop.",
        tools: [ADK.Tool.ExitLoop.tool()]
      )

      loop = ADK.Agent.LoopAgent.new(
        name: "loop",
        sub_agents: [agent],
        max_iterations: 10
      )

  The LLM will call `exit_loop` when it considers the task done, producing an
  escalation event that stops the loop immediately.
  """

  alias ADK.Tool.FunctionTool

  @doc """
  Create the `exit_loop` tool as a `FunctionTool`.

  The returned tool, when called by the LLM, returns `{:exit_loop, reason}`.
  `LlmAgent` intercepts this signal and emits an escalation event.

  ## Examples

      iex> tool = ADK.Tool.ExitLoop.tool()
      iex> tool.name
      "exit_loop"
  """
  @spec tool() :: FunctionTool.t()
  def tool do
    %FunctionTool{
      name: "exit_loop",
      description:
        "Exit the current loop when the task is complete. " <>
          "Call this to stop iterating and return results to the parent.",
      parameters: %{
        type: "object",
        properties: %{
          reason: %{
            type: "string",
            description:
              "Brief explanation of why the loop should exit (e.g. 'Task completed successfully')."
          }
        },
        required: []
      },
      func: fn _ctx, args ->
        reason = Map.get(args || %{}, "reason", "Task completed")
        {:exit_loop, reason}
      end
    }
  end

  @doc """
  Returns `true` if the given value is an exit_loop signal.

  ## Examples

      iex> ADK.Tool.ExitLoop.exit_loop?({:exit_loop, "done"})
      true
      iex> ADK.Tool.ExitLoop.exit_loop?({:ok, "result"})
      false
  """
  @spec exit_loop?(term()) :: boolean()
  def exit_loop?({:exit_loop, _reason}), do: true
  def exit_loop?(_), do: false

  @doc """
  Extract the reason from an exit_loop signal.

  ## Examples

      iex> ADK.Tool.ExitLoop.reason({:exit_loop, "all done"})
      "all done"
  """
  @spec reason({:exit_loop, String.t()}) :: String.t()
  def reason({:exit_loop, r}), do: r
end
