defmodule ADK.Agent.LlmAgent.ToolRoleTest do
  @moduledoc """
  Verifies that tool response events are sent to the LLM with the correct
  role (:user) rather than :model. Gemini requires function_response parts
  to appear in user-role messages.

  Regression test for: agent run stalls on tool-use queries because
  build_messages mapped tool response events to role: :model.
  """
  use ExUnit.Case, async: true

  setup do
    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)
    on_exit(fn -> Application.put_env(:adk, :llm_backend, ADK.LLM.Mock) end)
  end

  test "tool response events get :user role in messages sent to LLM" do
    # Track the request sent to the LLM on the second call (after tool execution)
    test_pid = self()

    # Custom backend that captures the second request
    defmodule CaptureMock do
      @behaviour ADK.LLM
      def generate(_model, request) do
        pid = Process.get(:test_pid)

        case Process.get(:call_count, 0) do
          0 ->
            Process.put(:call_count, 1)

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
            if pid, do: send(pid, {:llm_request, request})

            {:ok,
             %{
               content: %{role: :model, parts: [%{text: "It's sunny and 22°C."}]},
               usage_metadata: nil
             }}
        end
      end
    end

    Application.put_env(:adk, :llm_backend, CaptureMock)

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

    Process.put(:test_pid, test_pid)
    Process.put(:call_count, 0)

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
