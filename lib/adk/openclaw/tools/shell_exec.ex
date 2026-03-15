defmodule ADK.OpenClaw.Tools.ShellExec do
  @moduledoc """
  Tool for executing shell commands.
  """

  alias ADK.Tool.FunctionTool

  @doc """
  Returns a tool for executing shell commands.
  """
  def exec_command do
    FunctionTool.new(:exec,
      description: "Execute a shell command. Use this carefully.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The shell command to execute."}
        },
        required: ["command"]
      },
      func: fn _ctx, %{"command" => command} ->
        try do
          {output, status} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)

          if status == 0 do
            {:ok, output}
          else
            {:error, "Command failed with status #{status}:\n#{output}"}
          end
        rescue
          e -> {:error, "Exception executing command: #{inspect(e)}"}
        end
      end
    )
  end
end
