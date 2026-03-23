defmodule ADK.Skill.ExecTool do
  @moduledoc """
  Wraps a shell (`.sh`) or Python (`.py`) script as an ADK tool.

  The tool name is derived from the filename (without extension).
  The description is extracted from a `# description: ...` comment header.
  Input schema accepts a single `args` field (list of strings).
  """

  alias ADK.Tool.FunctionTool

  @default_timeout 30_000

  @type opts :: [timeout: pos_integer()]

  @doc """
  Create an ADK `FunctionTool` from a script path.

  ## Options

    * `:timeout` — execution timeout in ms (default: 30_000)
  """
  @spec new(Path.t(), opts()) :: FunctionTool.t()
  def new(script_path, opts \\ []) do
    name = Path.basename(script_path) |> Path.rootname()
    description = extract_description(script_path)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    FunctionTool.new(name,
      description: description,
      func: fn _ctx, args -> run_script(script_path, args, timeout) end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Command-line arguments to pass to the script"
          }
        }
      }
    )
  end

  @doc """
  Execute a script with the given arguments map.

  Returns `{:ok, stdout}` or `{:error, reason}`.
  """
  @spec run_script(Path.t(), map(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def run_script(script_path, args_map, timeout \\ @default_timeout) do
    args = Map.get(args_map, "args", []) |> List.wrap()
    ext = Path.extname(script_path)

    {cmd, cmd_args} =
      case ext do
        ".py" -> {"python3", [script_path | args]}
        ".sh" -> {"bash", [script_path | args]}
        _ -> {"bash", [script_path | args]}
      end

    task =
      Task.async(fn ->
        try do
          case System.cmd(cmd, cmd_args, stderr_to_stdout: false) do
            {stdout, 0} ->
              {:ok, String.trim(stdout)}

            {stdout, exit_code} ->
              {:error, "Script exited with code #{exit_code}: #{String.trim(stdout)}"}
          end
        rescue
          e ->
            {:error, "Script execution failed: #{inspect(e)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "Script timed out after #{timeout}ms"}
    end
  end

  defp extract_description(script_path) do
    case File.open(script_path, [:read, :utf8]) do
      {:ok, device} ->
        first_line = IO.read(device, :line)
        File.close(device)
        parse_description(first_line)

      _ ->
        ""
    end
  end

  defp parse_description(line) when is_binary(line) do
    case Regex.run(~r/^#\s*description:\s*(.+)$/i, String.trim(line)) do
      [_, desc] -> String.trim(desc)
      nil -> ""
    end
  end

  defp parse_description(_), do: ""
end
