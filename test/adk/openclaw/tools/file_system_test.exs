defmodule ADK.OpenClaw.Tools.FileSystemTest do
  use ExUnit.Case, async: true
  alias ADK.OpenClaw.Tools.FileSystem
  alias ADK.ToolContext

  setup do
    test_file = Path.join(System.tmp_dir!(), "openclaw_test_file.txt")
    on_exit(fn -> File.rm(test_file) end)
    {:ok, %{test_file: test_file}}
  end

  test "read_file tool reads an existing file", %{test_file: test_file} do
    File.write!(test_file, "Hello OpenClaw")
    tool = FileSystem.read_file()

    assert %ADK.Tool.FunctionTool{name: "read_file"} = tool

    assert {:ok, "Hello OpenClaw"} =
             ADK.Tool.FunctionTool.run(tool, %ToolContext{}, %{"path" => test_file})
  end

  test "write_file tool writes to a file", %{test_file: test_file} do
    tool = FileSystem.write_file()

    assert %ADK.Tool.FunctionTool{name: "write_file"} = tool

    assert {:ok, _} =
             ADK.Tool.FunctionTool.run(tool, %ToolContext{}, %{
               "path" => test_file,
               "content" => "Writing to OpenClaw"
             })

    assert File.read!(test_file) == "Writing to OpenClaw"
  end
end
