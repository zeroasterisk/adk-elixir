defmodule ADK.Tool.BashTool do
  @moduledoc """
  Tool to execute bash commands.

  This provides parity with the Python ADK `execute_bash` tool.

  ## Options

  - `:workspace` (String.t() | Path.t()) — The working directory for the command.
    Defaults to the current working directory (`File.cwd!()`).
  - `:allowed_prefixes` ([String.t()]) — A list of allowed command prefixes.
    Use `["*"]` to allow any command. Defaults to `["*"]`.
  """

  @tool_name "execute_bash"

  @doc """
  Build a bash tool instance.
  """
  @spec new(keyword()) :: ADK.Tool.FunctionTool.t()
  def new(opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || File.cwd!()
    allowed_prefixes = Keyword.get(opts, :allowed_prefixes, ["*"])

    desc_hint =
      if "*" in allowed_prefixes do
        "any command"
      else
        "commands matching prefixes: #{Enum.join(allowed_prefixes, ", ")}"
      end

    ADK.Tool.FunctionTool.new(@tool_name,
      description:
        "Executes a bash command with the working directory set to the workspace. Allowed: #{desc_hint}. All commands require user confirmation.",
      func: fn ctx, args -> execute(ctx, args, workspace, allowed_prefixes) end,
      parameters: %{
        type: "object",
        properties: %{
          command: %{
            type: "string",
            description: "The bash command to execute."
          }
        },
        required: ["command"]
      }
    )
  end

  @doc "The canonical tool name."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  defp execute(_ctx, %{"command" => command} = args, workspace, allowed_prefixes) do
    case validate_command(command, allowed_prefixes) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        case request_confirmation(@tool_name, args) do
          :allow ->
            run_command(command, workspace)

          {:deny, reason} ->
            {:error, "This tool call is rejected. Reason: #{reason}"}
        end
    end
  end

  defp execute(_ctx, _args, _workspace, _allowed_prefixes) do
    {:error, "Command is required."}
  end

  defp validate_command(nil, _), do: {:error, "Command is required."}
  defp validate_command("", _), do: {:error, "Command is required."}

  defp validate_command(command, allowed_prefixes) do
    stripped = String.trim(command)

    if stripped == "" do
      {:error, "Command is required."}
    else
      if "*" in allowed_prefixes do
        :ok
      else
        if Enum.any?(allowed_prefixes, fn prefix -> String.starts_with?(stripped, prefix) end) do
          :ok
        else
          {:error,
           "Command blocked. Permitted prefixes are: #{Enum.join(allowed_prefixes, ", ")}"}
        end
      end
    end
  end

  defp request_confirmation(tool_name, args) do
    if Process.whereis(ADK.Tool.Approval) do
      {req_id, _req} = ADK.Tool.Approval.register(ADK.Tool.Approval, tool_name, args)
      # Wait up to 5 minutes for approval
      case ADK.Tool.Approval.await(ADK.Tool.Approval, req_id, 300_000) do
        :allow -> :allow
        {:deny, reason} -> {:deny, reason}
      end
    else
      IO.puts(
        "\n[Confirmation Required] Please approve or reject the bash command: #{args["command"]}"
      )

      answer = IO.gets("Approve? [y/N]: ") || "n"
      answer = answer |> String.trim() |> String.downcase()

      if answer in ["y", "yes"] do
        :allow
      else
        {:deny, "User rejected"}
      end
    end
  end

  defp run_command(command, workspace) do
    case OptionParser.split(command) do
      [] ->
        {:error, "Command is empty."}

      [cmd | args] ->
        if System.find_executable(cmd) do
          try do
            {output, exit_status} = System.cmd(cmd, args, cd: workspace, stderr_to_stdout: true)

            {:ok,
             %{
               stdout: output,
               stderr: "",
               returncode: exit_status
             }}
          rescue
            e -> {:error, "Execution failed: #{Exception.message(e)}"}
          end
        else
          {:error, "Command not found: #{cmd}"}
        end
    end
  end
end
