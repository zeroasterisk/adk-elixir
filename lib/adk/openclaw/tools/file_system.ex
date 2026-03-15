defmodule ADK.OpenClaw.Tools.FileSystem do
  @moduledoc """
  File system tools for reading and writing files.
  """

  alias ADK.Tool.FunctionTool

  @doc """
  Returns a tool for reading a file.
  """
  def read_file do
    FunctionTool.new(:read_file,
      description: "Read the contents of a file.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file to read."}
        },
        required: ["path"]
      },
      func: fn _ctx, %{"path" => path} ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Failed to read file: #{reason}"}
        end
      end
    )
  end

  @doc """
  Returns a tool for writing a file.
  """
  def write_file do
    FunctionTool.new(:write_file,
      description: "Write content to a file, overwriting it if it exists.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file to write."},
          content: %{type: "string", description: "Content to write to the file."}
        },
        required: ["path", "content"]
      },
      func: fn _ctx, %{"path" => path, "content" => content} ->
        case File.write(path, content) do
          :ok -> {:ok, "Successfully wrote to #{path}"}
          {:error, reason} -> {:error, "Failed to write file: #{reason}"}
        end
      end
    )
  end
end
