defmodule Claw.Tools do
  @moduledoc """
  Tool implementations for Claw.

  Three tools:
  1. `datetime` — returns current date/time
  2. `read_file` — reads a file from disk (sandboxed to project dir)
  3. `shell_command` — runs a shell command (restricted to safe read-only commands)
  """

  alias ADK.Tool.FunctionTool

  @doc "All available tools."
  def all do
    [datetime(), read_file(), shell_command()]
  end

  @doc "Tool that returns the current date and time."
  def datetime do
    FunctionTool.new(:datetime,
      description: "Get the current date and time in UTC",
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      },
      func: fn _ctx, _args ->
        now = DateTime.utc_now()
        {:ok, "Current UTC time: #{DateTime.to_iso8601(now)}"}
      end
    )
  end

  @doc "Tool that reads a file from disk."
  def read_file do
    FunctionTool.new(:read_file,
      description: "Read the contents of a file. Path is relative to the project root.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "File path to read"}
        },
        required: ["path"]
      },
      func: fn _ctx, %{"path" => path} ->
        # Sandbox: only allow reading within the project
        safe_path = Path.expand(path, File.cwd!())

        if String.starts_with?(safe_path, File.cwd!()) do
          case File.read(safe_path) do
            {:ok, content} ->
              # Truncate large files
              truncated =
                if String.length(content) > 4000 do
                  String.slice(content, 0, 4000) <> "\n... (truncated)"
                else
                  content
                end

              {:ok, truncated}

            {:error, reason} ->
              {:error, "Cannot read file: #{reason}"}
          end
        else
          {:error, "Access denied: path outside project directory"}
        end
      end
    )
  end

  @doc "Tool that runs a sandboxed shell command."
  def shell_command do
    # Allowlist of safe commands
    allowed_prefixes = ~w[ls cat head tail wc echo date whoami uname pwd find grep]

    FunctionTool.new(:shell_command,
      description:
        "Run a shell command. Only safe read-only commands are allowed (ls, cat, head, tail, wc, echo, date, grep, find).",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Shell command to run"}
        },
        required: ["command"]
      },
      func: fn _ctx, %{"command" => command} ->
        # Extract the base command
        base_cmd =
          command
          |> String.trim()
          |> String.split(~r/\s+/, parts: 2)
          |> List.first()

        if base_cmd in allowed_prefixes do
          case System.cmd("sh", ["-c", command],
                 stderr_to_stdout: true
               ) do
            {output, 0} ->
              truncated =
                if String.length(output) > 4000 do
                  String.slice(output, 0, 4000) <> "\n... (truncated)"
                else
                  output
                end

              {:ok, truncated}

            {output, code} ->
              {:error, "Command exited with code #{code}: #{output}"}
          end
        else
          {:error,
           "Command '#{base_cmd}' not allowed. Allowed: #{Enum.join(allowed_prefixes, ", ")}"}
        end
      end
    )
  end
end
