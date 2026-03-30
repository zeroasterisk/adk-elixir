defmodule ADK.Integration.ToolsTest do
  @moduledoc """
  Parity test for Python ADK's tests/integration/test_tools.py

  Python test: skipped at module level (pytest.skip(allow_module_level=True)).
  Exercises an LLM agent with various tool types:
  - Simple function tools (single param, no param, no output, multiple types, lists)
  - Error-throwing function tools
  - Repetitive chained tool calls
  - Agent tools (sub-agent as tool)
  - File retrieval, RAG, LangChain/CrewAI tools (future parity)

  Elixir equivalent: verifies that an LlmAgent correctly invokes
  FunctionTools, handles errors, chains calls, and uses agent-as-tool,
  all via ADK.LLM.Mock.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ── Tool helper functions (mirrors Python fixtures) ──

  defp simple_function_tool do
    ADK.Tool.FunctionTool.new(:simple_function,
      description: "A simple function that takes a string param",
      func: fn _ctx, %{"param" => _param} -> {:ok, "Called simple function successfully"} end,
      parameters: %{
        type: "object",
        properties: %{param: %{type: "string"}},
        required: ["param"]
      }
    )
  end

  defp no_param_function_tool do
    ADK.Tool.FunctionTool.new(:no_param_function,
      description: "A function that takes no params",
      func: fn _ctx, _args -> {:ok, "Called no param function successfully"} end,
      parameters: %{type: "object", properties: %{}}
    )
  end

  defp no_output_function_tool do
    ADK.Tool.FunctionTool.new(:no_output_function,
      description: "A function that returns nothing",
      func: fn _ctx, %{"param" => _param} -> {:ok, nil} end,
      parameters: %{
        type: "object",
        properties: %{param: %{type: "string"}},
        required: ["param"]
      }
    )
  end

  defp multiple_param_types_function_tool do
    ADK.Tool.FunctionTool.new(:multiple_param_types_function,
      description: "A function with multiple param types",
      func: fn _ctx, %{"param1" => _, "param2" => _, "param3" => _, "param4" => _} ->
        {:ok, "Called multiple param types function successfully"}
      end,
      parameters: %{
        type: "object",
        properties: %{
          param1: %{type: "string"},
          param2: %{type: "integer"},
          param3: %{type: "number"},
          param4: %{type: "boolean"}
        },
        required: ["param1", "param2", "param3", "param4"]
      }
    )
  end

  defp throw_error_function_tool do
    ADK.Tool.FunctionTool.new(:throw_error_function,
      description: "A function that throws an error",
      func: fn _ctx, %{"param" => _param} ->
        {:error, "Error thrown by throw_error_function"}
      end,
      parameters: %{
        type: "object",
        properties: %{param: %{type: "string"}},
        required: ["param"]
      }
    )
  end

  defp list_str_param_function_tool do
    ADK.Tool.FunctionTool.new(:list_str_param_function,
      description: "A function that takes a list of strings",
      func: fn _ctx, %{"param" => _param} ->
        {:ok, "Called list str param function successfully"}
      end,
      parameters: %{
        type: "object",
        properties: %{param: %{type: "array", items: %{type: "string"}}},
        required: ["param"]
      }
    )
  end

  defp return_list_str_function_tool do
    ADK.Tool.FunctionTool.new(:return_list_str_function,
      description: "A function that returns a list of strings",
      func: fn _ctx, %{"param" => _param} ->
        {:ok, ["Called return list str function successfully"]}
      end,
      parameters: %{
        type: "object",
        properties: %{param: %{type: "string"}},
        required: ["param"]
      }
    )
  end

  defp repetitive_call_1_tool do
    ADK.Tool.FunctionTool.new(:repetitive_call_1,
      description: "First step in a repetitive chain",
      func: fn _ctx, %{"param" => param} ->
        {:ok, "Call repetitive_call_2 tool with param #{param}_repetitive"}
      end,
      parameters: %{
        type: "object",
        properties: %{param: %{type: "string"}},
        required: ["param"]
      }
    )
  end

  defp repetitive_call_2_tool do
    ADK.Tool.FunctionTool.new(:repetitive_call_2,
      description: "Second step in a repetitive chain",
      func: fn _ctx, %{"param" => param} -> {:ok, param} end,
      parameters: %{
        type: "object",
        properties: %{param: %{type: "string"}},
        required: ["param"]
      }
    )
  end

  # ── Helper to build agent + context + run ──

  defp run_agent(tools, mock_responses) do
    ADK.LLM.Mock.set_responses(mock_responses)

    agent =
      ADK.Agent.LlmAgent.new(
        name: "tools_test_agent",
        model: "test",
        instruction: "You are a helpful agent. Use your tools when asked.",
        tools: tools
      )

    {:ok, session_pid} =
      ADK.Session.start_link(
        app_name: "tools_test",
        user_id: "test_user",
        session_id: "tools-#{System.unique_integer([:positive])}",
        name: nil
      )

    ctx = %ADK.Context{
      invocation_id: "inv-tools-#{System.unique_integer([:positive])}",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "test input"}
    }

    events = ADK.Agent.run(agent, ctx)
    GenServer.stop(session_pid)
    events
  end

  # ── Tests ──

  describe "single function call" do
    test "simple_function returns success" do
      events =
        run_agent([simple_function_tool()], [
          # LLM decides to call simple_function
          %{function_call: %{name: "simple_function", args: %{"param" => "hello"}, id: "fc-1"}},
          # LLM produces final text after seeing tool result
          "The simple function was called successfully."
        ])

      # Should have tool call event + tool result + final text
      assert length(events) >= 2

      last = List.last(events)
      text = ADK.Event.text(last)
      assert text =~ "successfully"
    end

    test "no_param_function returns success" do
      events =
        run_agent([no_param_function_tool()], [
          %{function_call: %{name: "no_param_function", args: %{}, id: "fc-2"}},
          "No param function was called successfully."
        ])

      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "successfully"
    end

    test "no_output_function handles nil return" do
      events =
        run_agent([no_output_function_tool()], [
          %{function_call: %{name: "no_output_function", args: %{"param" => "test"}, id: "fc-3"}},
          "The function completed with no output."
        ])

      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "no output"
    end

    test "multiple_param_types_function handles diverse types" do
      events =
        run_agent([multiple_param_types_function_tool()], [
          %{
            function_call: %{
              name: "multiple_param_types_function",
              args: %{"param1" => "hello", "param2" => 42, "param3" => 3.14, "param4" => true},
              id: "fc-4"
            }
          },
          "Multiple param types function succeeded."
        ])

      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "succeeded"
    end

    test "list_str_param_function accepts list param" do
      events =
        run_agent([list_str_param_function_tool()], [
          %{
            function_call: %{
              name: "list_str_param_function",
              args: %{"param" => ["a", "b", "c"]},
              id: "fc-5"
            }
          },
          "List param function was called successfully."
        ])

      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "successfully"
    end

    test "return_list_str_function returns list" do
      events =
        run_agent([return_list_str_function_tool()], [
          %{
            function_call: %{
              name: "return_list_str_function",
              args: %{"param" => "test"},
              id: "fc-6"
            }
          },
          "Function returned a list successfully."
        ])

      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "successfully"
    end
  end

  describe "multiple function calls" do
    test "sequential calls to different tools" do
      events =
        run_agent(
          [
            simple_function_tool(),
            no_param_function_tool(),
            multiple_param_types_function_tool()
          ],
          [
            # First LLM turn: call simple_function
            %{
              function_call: %{name: "simple_function", args: %{"param" => "first"}, id: "fc-m1"}
            },
            # Second LLM turn: call no_param_function
            %{function_call: %{name: "no_param_function", args: %{}, id: "fc-m2"}},
            # Third LLM turn: call multiple_param_types_function
            %{
              function_call: %{
                name: "multiple_param_types_function",
                args: %{"param1" => "a", "param2" => 1, "param3" => 1.0, "param4" => false},
                id: "fc-m3"
              }
            },
            # Final response
            "All three tools were called successfully."
          ]
        )

      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "successfully"

      # Verify we got at least 4 events (3 tool rounds + final)
      assert length(events) >= 4
    end
  end

  describe "function call error" do
    test "throw_error_function propagates error back to LLM" do
      events =
        run_agent([throw_error_function_tool()], [
          %{
            function_call: %{
              name: "throw_error_function",
              args: %{"param" => "trigger"},
              id: "fc-err1"
            }
          },
          "The tool encountered an error."
        ])

      # The agent should continue after the error and produce a final response
      assert length(events) >= 2

      # The error flows as a function_response part back to the LLM.
      # Check that one of the events has content with a function_response
      # containing the error string.
      has_error_response =
        Enum.any?(events, fn event ->
          parts = get_in(event.content || %{}, [:parts]) || []

          Enum.any?(parts, fn part ->
            case part do
              %{function_response: %{response: resp}} ->
                resp_str = inspect(resp)
                resp_str =~ "Error thrown by throw_error_function"

              _ ->
                false
            end
          end)
        end)

      assert has_error_response,
             "Expected error from throw_error_function to be propagated as function_response"

      # Agent should still produce a final text response
      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "error"
    end
  end

  describe "repetitive chained calls" do
    test "repetitive_call_1 chains to repetitive_call_2" do
      events =
        run_agent(
          [repetitive_call_1_tool(), repetitive_call_2_tool()],
          [
            # LLM calls repetitive_call_1
            %{
              function_call: %{
                name: "repetitive_call_1",
                args: %{"param" => "start"},
                id: "fc-rep1"
              }
            },
            # LLM sees result and calls repetitive_call_2
            %{
              function_call: %{
                name: "repetitive_call_2",
                args: %{"param" => "start_repetitive"},
                id: "fc-rep2"
              }
            },
            # Final response
            "Chained calls completed: start_repetitive"
          ]
        )

      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "start_repetitive"

      # Should have at least 3 events (2 tool rounds + final)
      assert length(events) >= 3
    end
  end

  describe "agent tools (sub-agent as tool)" do
    test "agent-as-tool via sub-agent transfer" do
      # Python: AgentTool wraps a sub-agent. Elixir: use sub_agents + transfer
      ADK.LLM.Mock.set_responses([
        # Root agent transfers to helper
        %{
          function_call: %{
            name: "transfer_to_agent_helper_agent",
            args: %{},
            id: "fc-at1"
          }
        },
        # Helper agent responds
        "Helper agent processed the request successfully."
      ])

      helper_agent =
        ADK.Agent.LlmAgent.new(
          name: "helper_agent",
          model: "test",
          description: "A helper agent that processes requests",
          instruction: "You are a helper agent. Process any request and respond."
        )

      root_agent =
        ADK.Agent.LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "You are a root agent. Delegate to helper_agent when needed.",
          sub_agents: [helper_agent]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "agent_tool_test",
          user_id: "test_user",
          session_id: "agent-tool-#{System.unique_integer([:positive])}",
          name: nil
        )

      ctx = %ADK.Context{
        invocation_id: "inv-at-#{System.unique_integer([:positive])}",
        session_pid: session_pid,
        agent: root_agent,
        user_content: %{text: "Please process this request"}
      }

      events = ADK.Agent.run(root_agent, ctx)
      GenServer.stop(session_pid)

      # Verify transfer happened
      transfer_event =
        Enum.find(events, fn e ->
          e.actions && e.actions.transfer_to_agent == "helper_agent"
        end)

      assert transfer_event != nil, "Expected transfer to helper_agent"

      # Verify final response from helper
      last_text = events |> List.last() |> ADK.Event.text()
      assert last_text =~ "successfully"
    end
  end

  describe "future parity gaps" do
    @tag :skip
    test "file retrieval tools" do
      # Python ADK: uses FileRetrievalTool for grounding with file content
      # Elixir ADK: not yet implemented
      flunk("FileRetrievalTool not yet implemented in ADK Elixir")
    end

    @tag :skip
    test "RAG retrieval tools" do
      # Python ADK: uses RAGRetrievalTool for Vertex AI RAG
      # Elixir ADK: not yet implemented as a built-in tool
      flunk("RAGRetrievalTool not yet implemented in ADK Elixir")
    end

    @tag :skip
    test "LangChain tools" do
      # Python ADK: wraps LangChain tools via LangchainTool adapter
      # Elixir ADK: no equivalent (LangChain is Python-only ecosystem)
      flunk("LangChain tool adapter not applicable to Elixir")
    end

    @tag :skip
    test "CrewAI tools" do
      # Python ADK: wraps CrewAI tools via CrewaiTool adapter
      # Elixir ADK: no equivalent (CrewAI is Python-only ecosystem)
      flunk("CrewAI tool adapter not applicable to Elixir")
    end
  end
end
