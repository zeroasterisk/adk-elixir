defmodule ADK.Agent.LlmAgent.ToolRoleTest do
  @moduledoc """
  Verifies that tool response events are sent to the LLM with the correct
  role (:user) rather than :model. Gemini requires function_response parts
  to appear in user-role messages.

  Regression test for: agent run stalls on tool-use queries because
  build_messages mapped tool response events to role: :model.

  Uses async: false because the inline mock module mutates global Application
  env and uses an ETS table for cross-process state.
  """
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)
    on_exit(fn -> Application.put_env(:adk, :llm_backend, ADK.LLM.Mock) end)
  end

  defmodule ToolRoleCaptureMock do
    @moduledoc false
    @behaviour ADK.LLM

    def init(test_pid) do
      table = :ets.new(:tool_role_capture, [:public, :named_table])
      :ets.insert(table, {:test_pid, test_pid})
      :ets.insert(table, {:call_count, 0})
      table
    end

    def cleanup do
      try do
        :ets.delete(:tool_role_capture)
      rescue
        _ -> :ok
      end
    end

    def generate(_model, request) do
      count =
        case :ets.lookup(:tool_role_capture, :call_count) do
          [{_, n}] -> n
          _ -> 0
        end

      :ets.insert(:tool_role_capture, {:call_count, count + 1})

      case count do
        0 ->
          # First call: return a tool call
          {:ok,
           %{
             content: %{
               role: :model,
               parts: [
                 %{
                   function_call: %{
                     name: "web_search",
                     args: %{"query" => "weather today"}
                   }
                 }
               ]
             },
             usage_metadata: nil
           }}

        _ ->
          # Second call: capture request and return final text
          pid =
            case :ets.lookup(:tool_role_capture, :test_pid) do
              [{_, p}] -> p
              _ -> nil
            end

          if pid, do: send(pid, {:llm_request, request})

          {:ok,
           %{
             content: %{role: :model, parts: [%{text: "It's sunny and 22°C."}]},
             usage_metadata: nil
           }}
      end
    end
  end

  test "tool response events get :user role in messages sent to LLM" do
    ToolRoleCaptureMock.init(self())
    on_exit(fn -> ToolRoleCaptureMock.cleanup() end)

    Application.put_env(:adk, :llm_backend, ToolRoleCaptureMock)

    tool =
      ADK.Tool.FunctionTool.new(:web_search,
        description: "Search the web",
        func: fn _ctx, _args -> {:ok, Jason.encode!([%{title: "Weather", snippet: "Sunny 22°C"}])} end,
        parameters: %{
          type: "object",
          properties: %{query: %{type: "string"}},
          required: ["query"]
        }
      )

    agent =
      ADK.Agent.LlmAgent.new(
        name: "weather_bot",
        model: "test",
        instruction: "Help with weather.",
        tools: [tool]
      )

    {:ok, session_pid} =
      ADK.Session.start_link(app_name: "test_role", user_id: "u1", session_id: "role_test")

    ctx = %ADK.Context{
      invocation_id: "inv-role",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "What's the weather?"}
    }

    events = ADK.Agent.run(agent, ctx)

    # Should complete with a final text response
    last = List.last(events)
    assert ADK.Event.text(last) == "It's sunny and 22°C."

    # Verify the second LLM request had correct roles
    assert_receive {:llm_request, request}, 1000

    messages = request[:messages] || request["messages"]
    assert is_list(messages)

    # Find the message containing function_response parts
    tool_response_msg =
      Enum.find(messages, fn msg ->
        parts = msg[:parts] || msg["parts"] || []

        Enum.any?(parts, fn
          %{function_response: _} -> true
          %{"function_response" => _} -> true
          _ -> false
        end)
      end)

    assert tool_response_msg != nil,
           "Expected a message with function_response parts, got: #{inspect(messages)}"

    assert tool_response_msg.role == :user,
           "function_response message must have role :user, got: #{inspect(tool_response_msg.role)}"

    GenServer.stop(session_pid)
  end
end
