defmodule ADK.OpenClaw.Tools.ShellExecTest do
  use ExUnit.Case, async: true
  alias ADK.OpenClaw.Tools.ShellExec
  alias ADK.ToolContext

  test "exec_command executes a basic shell command" do
    tool = ShellExec.exec_command()

    assert %ADK.Tool.FunctionTool{name: "exec"} = tool

    assert {:ok, output} =
             ADK.Tool.FunctionTool.run(tool, %ToolContext{}, %{
               "command" => "echo 'Hello OpenClaw'"
             })

    assert output =~ "Hello OpenClaw"
  end

  test "exec_command returns error on failure" do
    tool = ShellExec.exec_command()

    assert {:error, output} =
             ADK.Tool.FunctionTool.run(tool, %ToolContext{}, %{"command" => "exit 1"})

    assert output =~ "Command failed"
  end
end
