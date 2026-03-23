defmodule ADK.Tool.CodeExecutionParityTest do
  @moduledoc """
  Parity tests for BuiltInCodeExecution logic, mirroring Python ADK's
  `tests/unittests/flows/llm_flows/test_code_execution.py`.

  Tests:
  - Tool declaration and mapping to Gemini format.
  - Native code execution result/event handling in LlmAgent.
  - Error handling for direct invocations (must be handled natively).
  """
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Context
  alias ADK.Runner
  alias ADK.Tool.BuiltInCodeExecution

  setup do
    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)

    on_exit(fn ->
      Application.delete_env(:adk, :llm_backend)
    end)

    :ok
  end

  describe "BuiltInCodeExecution declaration" do
    test "tool correctly defines __builtin__ property" do
      tool = BuiltInCodeExecution.new()
      assert tool.name == "code_execution"
      assert tool.__builtin__ == :code_execution
    end

    test "LlmAgent correctly adds built-in tool to LLM request" do
      agent =
        LlmAgent.new(
          name: "coder",
          model: "gemini-flash",
          instruction: "Run code.",
          tools: [BuiltInCodeExecution.new()]
        )

      ctx = %Context{
        invocation_id: "inv-1",
        session_pid: nil,
        agent: agent,
        user_content: %{text: "hi"}
      }

      req = LlmAgent.build_request(ctx, agent)
      assert length(req.tools) == 1
      assert hd(req.tools).__builtin__ == :code_execution
      assert hd(req.tools).name == "code_execution"
    end
  end

  describe "Code execution events processing" do
    test "Runner emits events containing executable_code and code_execution_result" do
      agent =
        LlmAgent.new(
          name: "code_agent",
          model: "test-model",
          tools: [BuiltInCodeExecution.new()]
        )

      runner = Runner.new(app_name: "test_app", agent: agent)

      # We mock the LLM to return these natively-executed parts
      # (since Gemini backend does this for us and parses them natively)
      mock_response = %{
        content: %{
          role: :model,
          parts: [
            %{text: "Here is the code:"},
            %{executable_code: %{language: "PYTHON", code: "print('hello')"}},
            %{code_execution_result: %{outcome: "OUTCOME_OK", output: "hello\n"}},
            %{text: "Output was hello"}
          ]
        }
      }

      ADK.LLM.Mock.set_responses([mock_response])

      events = Runner.run(runner, "user-1", "sess-1", "Run print('hello')")

      # The user event is appended to session but runner returns only agent events
      assert length(events) == 1
      [model_event] = events

      assert model_event.author == "code_agent"
      assert length(model_event.content.parts) == 4

      # Verify the specific code parts are passed through
      assert Enum.at(model_event.content.parts, 1).executable_code.code == "print('hello')"
      assert Enum.at(model_event.content.parts, 2).code_execution_result.outcome == "OUTCOME_OK"
      assert Enum.at(model_event.content.parts, 2).code_execution_result.output == "hello\n"
    end
  end

  describe "Error handling / Argument mapping" do
    test "direct execution of the tool returns an explicit error" do
      tool = BuiltInCodeExecution.new()
      
      ctx = %Context{
        invocation_id: "inv-1",
        session_pid: nil,
        agent: LlmAgent.new(name: "dummy", model: "test"),
        user_content: %{text: "hi"}
      }
      
      # The tool cannot be executed natively within Elixir 
      # as Gemini handles it transparently via the backend.
      result = BuiltInCodeExecution.run(ADK.ToolContext.new(ctx, "call-1", tool), %{"some_arg" => "ignored"})
      
      assert {:error, msg} = result
      assert msg =~ "BuiltInCodeExecution is a built-in Gemini tool"
      assert msg =~ "cannot be called directly"
    end
  end
end
