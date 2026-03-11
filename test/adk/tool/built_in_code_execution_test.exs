defmodule ADK.Tool.BuiltInCodeExecutionTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.BuiltInCodeExecution

  describe "new/0" do
    test "creates a BuiltInCodeExecution struct" do
      tool = BuiltInCodeExecution.new()
      assert %BuiltInCodeExecution{} = tool
      assert tool.name == "code_execution"
      assert tool.__builtin__ == :code_execution
    end
  end

  describe "ADK.Tool.declaration/1" do
    test "declaration preserves __builtin__ marker" do
      tool = BuiltInCodeExecution.new()
      decl = ADK.Tool.declaration(tool)
      assert decl.__builtin__ == :code_execution
      assert decl.name == "code_execution"
    end
  end

  describe "ADK.Tool.builtin?/1" do
    test "returns true for BuiltInCodeExecution" do
      tool = BuiltInCodeExecution.new()
      assert ADK.Tool.builtin?(tool)
    end
  end

  describe "run/2" do
    test "returns error (stub — native tool)" do
      tool = BuiltInCodeExecution.new()
      assert {:error, msg} = BuiltInCodeExecution.run(nil, %{})
      assert msg =~ "built-in"
    end
  end
end
