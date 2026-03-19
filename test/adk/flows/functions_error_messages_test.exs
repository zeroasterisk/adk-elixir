# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Flows.FunctionsErrorMessagesTest do
  @moduledoc """
  Parity tests for Python's test_functions_error_messages.py

  Verifies enhanced error messages when an LLM requests a tool that doesn't
  exist — the error is propagated back to the LLM via function_response
  with a descriptive message including the unknown tool name.

  In Python ADK, `_get_tool` raises a ValueError with structured diagnostics.
  In Elixir ADK, `execute_tools/3` returns `%{error: "Unknown tool: <name>"}`,
  which gets wrapped into a function_response sent back to the LLM so it can
  self-correct or explain the error.
  """
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Tool.FunctionTool

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ---------- helpers ----------

  defp make_tool(name) do
    FunctionTool.new(name,
      description: "Mock tool: #{name}",
      func: fn _ctx, _args -> {:ok, "mock_response"} end,
      parameters: %{}
    )
  end

  defp run_agent_with_tools(tools, function_call_name) do
    # LLM first requests a (possibly unknown) tool, then gives a final answer
    ADK.LLM.Mock.set_responses([
      %{function_call: %{name: function_call_name, args: %{}, id: "fc-1"}},
      "Done"
    ])

    agent =
      LlmAgent.new(
        name: "bot",
        model: "test",
        instruction: "Use tools",
        tools: tools
      )

    {:ok, session_pid} =
      ADK.Session.start_link(
        app_name: "err-msg-test",
        user_id: "u1",
        session_id: "s-#{System.unique_integer([:positive])}"
      )

    ctx = %ADK.Context{
      invocation_id: "inv-#{System.unique_integer([:positive])}",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "do it"}
    }

    events = ADK.Agent.run(agent, ctx)
    GenServer.stop(session_pid)
    events
  end

  # Content can be atom-keyed or string-keyed depending on source
  defp get_parts(%{content: content}) when is_map(content) do
    Map.get(content, :parts) || Map.get(content, "parts") || []
  end

  defp get_parts(_), do: []

  defp find_tool_response_event(events) do
    Enum.find(events, fn event ->
      parts = get_parts(event)

      Enum.any?(parts, fn
        %{function_response: _} -> true
        %{"function_response" => _} -> true
        _ -> false
      end)
    end)
  end

  defp get_function_responses(event) do
    parts = get_parts(event)

    Enum.flat_map(parts, fn
      %{function_response: fr} -> [fr]
      %{"function_response" => fr} -> [fr]
      _ -> []
    end)
  end

  defp response_text(fr) do
    resp = fr[:response] || fr["response"] || %{}
    result = resp["result"] || resp[:result] || ""
    to_string(result)
  end

  defp get_event_text(event) do
    parts = get_parts(event)

    Enum.find_value(parts, fn
      %{text: t} when is_binary(t) -> t
      %{"text" => t} when is_binary(t) -> t
      _ -> nil
    end)
  end

  # ---------- tests ----------

  describe "tool not found — error propagated to LLM" do
    test "unknown tool name appears in error response" do
      tools = [make_tool("get_weather"), make_tool("calculate_sum")]
      events = run_agent_with_tools(tools, "nonexistent_tool")

      response_event = find_tool_response_event(events)
      assert response_event, "Expected a function_response event for the tool call"

      [fr] = get_function_responses(response_event)
      text = response_text(fr)
      assert text =~ "nonexistent_tool", "Error should mention the unknown tool name"
    end

    test "error response contains 'Unknown tool' marker" do
      tools = [make_tool("get_weather")]
      events = run_agent_with_tools(tools, "completely_different")

      response_event = find_tool_response_event(events)
      assert response_event

      [fr] = get_function_responses(response_event)
      text = response_text(fr)
      assert text =~ "Unknown tool"
      assert text =~ "completely_different"
    end

    test "error response is sent for the correct tool name in function_response" do
      tools = [make_tool("alpha"), make_tool("beta"), make_tool("gamma")]
      events = run_agent_with_tools(tools, "delta")

      response_event = find_tool_response_event(events)
      assert response_event

      [fr] = get_function_responses(response_event)
      name = fr[:name] || fr["name"]
      assert name == "delta"
    end

    test "agent still produces final text response after unknown tool error" do
      tools = [make_tool("search")]
      events = run_agent_with_tools(tools, "nonexistent")

      texts =
        events
        |> Enum.map(&get_event_text/1)
        |> Enum.filter(& &1)

      assert "Done" in texts,
             "Agent should continue and produce final response after tool error"
    end
  end

  describe "tool found — normal execution" do
    test "known tool executes successfully without error" do
      tools = [make_tool("get_weather")]
      events = run_agent_with_tools(tools, "get_weather")

      response_event = find_tool_response_event(events)
      assert response_event

      [fr] = get_function_responses(response_event)
      text = response_text(fr)
      refute text =~ "Unknown tool", "Known tool should not produce an error"
    end
  end

  describe "tool execution error formatting" do
    test "tool returning {:error, reason} is wrapped as function_response" do
      error_tool =
        FunctionTool.new("flaky_tool",
          description: "A tool that fails",
          func: fn _ctx, _args -> {:error, "connection timeout"} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "flaky_tool", args: %{}, id: "fc-1"}},
        "Handled the error"
      ])

      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Use tools",
          tools: [error_tool]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "err-fmt", user_id: "u1", session_id: "s-err")

      ctx = %ADK.Context{
        invocation_id: "inv-err",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "do it"}
      }

      events = ADK.Agent.run(agent, ctx)
      GenServer.stop(session_pid)

      response_event = find_tool_response_event(events)
      assert response_event, "Tool error should still produce function_response"

      [fr] = get_function_responses(response_event)
      text = response_text(fr)
      assert text =~ "connection timeout"
    end

    test "different error reasons are preserved in response" do
      error_tool =
        FunctionTool.new("db_tool",
          description: "DB query",
          func: fn _ctx, _args -> {:error, "table not found: users"} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "db_tool", args: %{}, id: "fc-1"}},
        "OK"
      ])

      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Use tools",
          tools: [error_tool]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "err-fmt2", user_id: "u1", session_id: "s-err2")

      ctx = %ADK.Context{
        invocation_id: "inv-err2",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "query"}
      }

      events = ADK.Agent.run(agent, ctx)
      GenServer.stop(session_pid)

      response_event = find_tool_response_event(events)
      [fr] = get_function_responses(response_event)
      text = response_text(fr)
      assert text =~ "table not found"
    end
  end
end
