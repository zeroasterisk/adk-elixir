defmodule ADK.Skill.Script do
  @moduledoc """
  Discovers and wraps scripts in a skill's `scripts/` directory as ADK tools.

  Supported file types:

  - `.sh` — executed via `bash`
  - `.py` — executed via `python3`
  - `.exs` — evaluated via `Code.eval_file`
  - `mcp.json` — MCP server config (discovered but not started)

  Each script becomes a `FunctionTool` with a single `input` string parameter.
  The tool name is derived from the filename (e.g., `lint.sh` → `run_lint`).
  The description is taken from the first comment line, or defaults to
  "Run {filename}".
  """

  alias ADK.Tool.FunctionTool

  @type discovery :: %{tools: [FunctionTool.t()], mcp_configs: [map()]}

  @doc """
  Discover scripts in the given directory.

  Returns a map with `:tools` (list of FunctionTool) and `:mcp_configs`
  (list of parsed MCP JSON configs).
  """
  @spec discover(Path.t()) :: discovery()
  def discover(dir) do
    scripts_dir = Path.join(dir, "scripts")

    if File.dir?(scripts_dir) do
      files = File.ls!(scripts_dir) |> Enum.sort()

      {tools, mcp_configs} =
        Enum.reduce(files, {[], []}, fn filename, {tools_acc, mcp_acc} ->
          path = Path.join(scripts_dir, filename)

          cond do
            filename == "mcp.json" ->
              case parse_mcp_config(path) do
                {:ok, config} -> {tools_acc, [config | mcp_acc]}
                _ -> {tools_acc, mcp_acc}
              end

            Path.extname(filename) in [".sh", ".py", ".exs"] ->
              {[build_tool(path, filename) | tools_acc], mcp_acc}

            true ->
              {tools_acc, mcp_acc}
          end
        end)

      %{tools: Enum.reverse(tools), mcp_configs: Enum.reverse(mcp_configs)}
    else
      %{tools: [], mcp_configs: []}
    end
  end

  defp build_tool(path, filename) do
    ext = Path.extname(filename)
    base = Path.rootname(filename)
    name = "run_#{base}"
    description = extract_description(path, ext) || "Run #{filename}"

    FunctionTool.new(name,
      description: description,
      func: fn args ->
        input = Map.get(args, "input", "")
        execute(path, ext, input)
      end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string", "description" => "Input to pass to the script"}
        }
      }
    )
  end

  @doc false
  def execute(path, ext, input) do
    case ext do
      ".sh" -> run_cmd("bash", [path, input])
      ".py" -> run_cmd("python3", [path, input])
      ".exs" -> run_exs(path, input)
      _ -> {:error, "Unsupported script type: #{ext}"}
    end
  end

  defp run_cmd(cmd, args) do
    try do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output)}
        {output, code} -> {:error, "Exit code #{code}: #{String.trim(output)}"}
      end
    rescue
      e -> {:error, "Execution failed: #{Exception.message(e)}"}
    end
  end

  defp run_exs(path, input) do
    try do
      code = File.read!(path)
      {result, _binding} = Code.eval_string(code, [input: input], file: path)
      {:ok, inspect_or_string(result)}
    rescue
      e -> {:error, "Elixir script failed: #{Exception.message(e)}"}
    end
  end

  defp inspect_or_string(val) when is_binary(val), do: val
  defp inspect_or_string(val), do: inspect(val)

  defp extract_description(path, ext) do
    case File.open(path, [:read, :utf8]) do
      {:ok, device} ->
        line = IO.read(device, :line)
        File.close(device)
        parse_comment(line, ext)

      _ ->
        nil
    end
  end

  defp parse_comment(line, ext) when is_binary(line) do
    pattern =
      case ext do
        ".py" -> ~r/^#\s*(.+)$/
        ".sh" -> ~r/^#!\s*.+$|^#\s*(.+)$/
        ".exs" -> ~r/^#\s*(.+)$/
        _ -> ~r/^#\s*(.+)$/
      end

    case Regex.run(pattern, String.trim(line)) do
      [_, "!" <> _] -> nil
      [_, desc] when is_binary(desc) -> String.trim(desc)
      # shebang line for .sh — skip
      [_] -> nil
      nil -> nil
    end
  end

  defp parse_comment(_, _), do: nil

  defp parse_mcp_config(path) do
    with {:ok, content} <- File.read(path),
         {:ok, config} <- Jason.decode(content) do
      {:ok, config}
    end
  end
end
