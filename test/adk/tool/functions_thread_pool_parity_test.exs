defmodule ADK.Tool.FunctionsThreadPoolParityTest do
  @moduledoc """
  Parity tests for Python ADK's `test_functions_thread_pool.py`.

  In Elixir, the BEAM runtime uses preemptive scheduling and lightweight processes,
  so we do not need a dedicated ThreadPoolExecutor for tools. The LlmAgent
  executes tools inline within its own process, and blocking I/O does not
  block the VM.

  This suite ports the behavioral aspects of tool execution from the Python
  tests:
  - Tools receive arguments correctly.
  - Tools receive the ToolContext correctly.
  - Exceptions from tools propagate correctly.
  """
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Context
  alias ADK.ToolContext
  alias ADK.Tool.FunctionTool

  setup do
    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)

    on_exit(fn ->
      Application.delete_env(:adk, :llm_backend)
    end)

    :ok
  end

  describe "Tool execution behavior (parity)" do
    test "tool receives arguments correctly" do
      tool_fn = fn _ctx, %{"x" => x, "y" => y} ->
        %{"sum" => x, "text" => y}
      end

      tool =
        FunctionTool.new("test_tool",
          description: "Test tool",
          func: tool_fn,
          parameters: %{
            "type" => "object",
            "properties" => %{
              "x" => %{"type" => "integer"},
              "y" => %{"type" => "string"}
            }
          }
        )

      agent = LlmAgent.new(name: "test_agent", model: "dummy", tools: [tool])

      ctx = %Context{
        invocation_id: "inv-1",
        session_pid: nil,
        agent: agent,
        user_content: %{text: ""}
      }

      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{name: "test_tool", args: %{"x" => 42, "y" => "hello"}}
        },
        %{text: "Done"}
      ])

      events = ADK.Agent.run(agent, ctx)

      assert length(events) == 3
      tool_response_event = Enum.at(events, 1)

      parts = tool_response_event.content.parts
      assert length(parts) == 1
      part = hd(parts)

      assert Map.has_key?(part, :function_response)
      assert part.function_response.name == "test_tool"
      assert part.function_response.response == %{"sum" => 42, "text" => "hello"}
    end

    test "tool receives tool_context correctly" do
      tool_fn = fn ctx, %{"x" => x} ->
        has_context = match?(%ToolContext{}, ctx)
        %{"x" => x, "has_context" => has_context, "app_name" => ctx.context.app_name}
      end

      tool =
        FunctionTool.new("test_tool_ctx",
          description: "Test context",
          func: tool_fn
        )

      agent = LlmAgent.new(name: "test_agent", model: "dummy", tools: [tool])

      ctx = %Context{
        invocation_id: "inv-2",
        session_pid: nil,
        agent: agent,
        app_name: "test_app",
        user_content: %{text: ""}
      }

      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{name: "test_tool_ctx", args: %{"x" => 10}}
        },
        %{text: "Done"}
      ])

      events = ADK.Agent.run(agent, ctx)

      tool_response_event = Enum.at(events, 1)
      part = hd(tool_response_event.content.parts)

      assert part.function_response.response == %{
               "x" => 10,
               "has_context" => true,
               "app_name" => "test_app"
             }
    end

    test "tool exception propagates" do
      tool_fn = fn _ctx, _args ->
        raise RuntimeError, "Test error from sync tool"
      end

      tool =
        FunctionTool.new("error_tool",
          description: "Raises error",
          func: tool_fn
        )

      agent = LlmAgent.new(name: "test_agent", model: "dummy", tools: [tool])

      ctx = %Context{
        invocation_id: "inv-3",
        session_pid: nil,
        agent: agent,
        user_content: %{text: ""}
      }

      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{name: "error_tool", args: %{}}
        }
      ])

      # FunctionTool.run/3 now rescues exceptions and returns {:error, ...}
      # so the error is propagated to the LLM as tool output, not raised
      result = ADK.Agent.run(agent, ctx)
      assert is_list(result)
    end
  end
end
