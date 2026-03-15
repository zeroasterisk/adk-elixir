defmodule ADK.CodeExecutorTest do
  use ExUnit.Case, async: true

  describe "UnsafeLocal" do
    test "executes simple code successfully" do
      executor = %ADK.CodeExecutor.UnsafeLocal{}
      input = %ADK.CodeExecutor.Input{code: "1 + 1"}

      result = ADK.CodeExecutor.UnsafeLocal.execute_code(executor, nil, input)
      assert result.stdout == "2"
      assert result.stderr == ""
    end

    test "captures exceptions in stderr" do
      executor = %ADK.CodeExecutor.UnsafeLocal{}
      input = %ADK.CodeExecutor.Input{code: "raise \"boom\""}

      result = ADK.CodeExecutor.UnsafeLocal.execute_code(executor, nil, input)
      assert result.stdout == ""
      assert result.stderr =~ "** (RuntimeError) boom"
    end
  end

  describe "VertexAI" do
    test "returns not implemented error currently" do
      executor = %ADK.CodeExecutor.VertexAI{}
      input = %ADK.CodeExecutor.Input{code: "1 + 1"}

      result = ADK.CodeExecutor.VertexAI.execute_code(executor, nil, input)
      assert result == {:error, "Not implemented: Requires full Vertex AI native API integration"}
    end
  end
end
