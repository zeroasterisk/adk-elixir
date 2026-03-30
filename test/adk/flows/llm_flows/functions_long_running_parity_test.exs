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

defmodule ADK.Flows.LlmFlows.FunctionsLongRunningParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_functions_long_running.py`.

  The Python test exercises a multi-turn runner flow where a
  `LongRunningFunctionTool` returns a pending status, and subsequent
  user messages supply progress updates until a final result arrives.
  The LLM sees the full conversation history at each turn.

  In Elixir, `ADK.Tool.LongRunningTool` runs the tool function in a
  supervised Task and blocks (with timeout) until completion, so the
  "pending → progress → complete" cycle happens within a single
  `Runner.run/5` call rather than across multiple turns.

  These tests verify the key behavioral invariants that DO carry over:

  1. Tool function is called exactly once per function_call
  2. LongRunningTool result (including map/pending/status) flows through
     the runner's tool → function_response → LLM loop correctly
  3. Status updates from the tool are captured in the result
  4. The LLM receives the function_response and produces a final text reply
  5. Error/timeout in long-running tools propagates correctly through runner
  6. Multiple long-running tools can execute in one agent

  Python-only tests NOT directly ported (and why):
  - Multi-turn pending/update/complete cycle — Python's external async
    pattern; Elixir resolves within a single run via OTP Task
  - `long_running_tool_ids` on events — only set in Elixir's auth/toolset
    path, not in the main runner flow
  - `runner.run(UserContent(function_response))` — Elixir runner doesn't
    accept raw function_response parts as user input
  """

  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Runner
  alias ADK.Tool.LongRunningTool

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp run_agent(agent, message) do
    runner = Runner.new(app_name: "fn_lr_test", agent: agent)
    sid = "s-#{System.unique_integer([:positive])}"
    Runner.run(runner, "u1", sid, message)
  end

  defp text_events(events) do
    events
    |> Enum.map(&extract_text/1)
    |> Enum.filter(& &1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_text(%{content: content}) when is_map(content) do
    parts = Map.get(content, :parts) || Map.get(content, "parts") || []

    Enum.find_value(parts, fn
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end)
  end

  defp extract_text(_), do: nil

  defp function_call_events(events) do
    Enum.filter(events, fn e ->
      parts = get_parts(e)
      Enum.any?(parts, &(Map.has_key?(&1, :function_call) or Map.has_key?(&1, "function_call")))
    end)
  end

  defp function_response_events(events) do
    Enum.filter(events, fn e ->
      parts = get_parts(e)

      Enum.any?(
        parts,
        &(Map.has_key?(&1, :function_response) or Map.has_key?(&1, "function_response"))
      )
    end)
  end

  defp get_parts(%{content: content}) when is_map(content) do
    Map.get(content, :parts) || Map.get(content, "parts") || []
  end

  defp get_parts(_), do: []

  defp get_function_response(part) do
    Map.get(part, :function_response) || Map.get(part, "function_response")
  end

  defp get_fr_response(fr) when is_map(fr) do
    Map.get(fr, :response) || Map.get(fr, "response")
  end

  defp get_fr_response(_), do: nil

  defp collect_fr_responses(events) do
    events
    |> function_response_events()
    |> Enum.flat_map(fn e ->
      get_parts(e)
      |> Enum.map(&get_function_response/1)
      |> Enum.filter(& &1)
    end)
  end

  # ====================================================================
  # 1. LongRunningTool through full runner pipeline
  #    (test_functions_long_running.py :: test_async_function — core flow)
  #
  #    Python: tool returns {'status': 'pending'}, LLM gets function_response
  #    Elixir: tool runs in Task, result flows through runner pipeline
  # ====================================================================

  describe "long-running tool through runner pipeline" do
    test "tool returning a map result flows through runner correctly" do
      counter = :counters.new(1, [:atomics])

      tool =
        LongRunningTool.new(:increase_by_one,
          description: "Increment by one",
          func: fn _ctx, %{"x" => x}, _send_update ->
            :counters.add(counter, 1, 1)
            %{"status" => "complete", "result" => x + 1}
          end,
          parameters: %{
            type: "object",
            properties: %{x: %{type: "integer"}},
            required: ["x"]
          },
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "increase_by_one", args: %{"x" => 1}, id: "fc-1"}},
        "The result is 2"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      events = run_agent(agent, "increase 1")

      # Tool called exactly once (parity with Python: assert function_called == 1)
      assert :counters.get(counter, 1) == 1

      # One function_call event, one function_response event
      assert length(function_call_events(events)) == 1
      assert length(function_response_events(events)) == 1

      # Function response carries the tool's return value
      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      assert response == %{"status" => "complete", "result" => 2}

      # LLM produces final text
      assert "The result is 2" in text_events(events)
    end

    test "tool returning pending status map flows through runner" do
      # Mirrors Python's test_async_function where tool returns {'status': 'pending'}
      # In Elixir, the tool still returns this synchronously, and it flows to the LLM

      tool =
        LongRunningTool.new(:slow_task,
          description: "A slow task",
          func: fn _ctx, _args, _send_update ->
            %{"status" => "pending"}
          end,
          parameters: %{},
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "slow_task", args: %{}, id: "fc-1"}},
        "Task is pending, please wait"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      events = run_agent(agent, "start task")

      # Function response contains the pending status
      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      assert response == %{"status" => "pending"}

      # LLM still responds
      assert "Task is pending, please wait" in text_events(events)
    end
  end

  # ====================================================================
  # 2. Tool with status updates through runner
  #    Python: no direct equivalent (Python uses multi-turn for progress)
  #    Elixir: status updates are captured in the tool result
  # ====================================================================

  describe "status updates through runner" do
    test "status updates are included in function response result" do
      tool =
        LongRunningTool.new(:process_data,
          description: "Process data with progress",
          func: fn _ctx, %{"items" => n}, send_update ->
            send_update.("Processing #{n} items...")
            send_update.("Almost done...")
            %{"processed" => n, "status" => "complete"}
          end,
          parameters: %{
            type: "object",
            properties: %{items: %{type: "integer"}},
            required: ["items"]
          },
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "process_data", args: %{"items" => 100}, id: "fc-1"}},
        "Processed 100 items successfully"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      events = run_agent(agent, "process 100 items")

      # Result should contain both the final value and status updates
      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))

      # LongRunningTool wraps result with atom keys: %{result: val, status_updates: [...]}
      # wrap_tool_response passes maps through as-is, so the function_response
      # contains the wrapped map with atom keys
      assert response[:result] == %{"processed" => 100, "status" => "complete"}
      assert response[:status_updates] == ["Processing 100 items...", "Almost done..."]

      assert "Processed 100 items successfully" in text_events(events)
    end

    test "tool without status updates returns plain result" do
      tool =
        LongRunningTool.new(:quick_task,
          description: "Quick task",
          func: fn _ctx, _args, _send_update ->
            "done"
          end,
          parameters: %{},
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "quick_task", args: %{}, id: "fc-1"}},
        "Task completed"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      events = run_agent(agent, "do task")

      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      # No updates, so result is unwrapped
      assert response == %{"result" => "done"}

      assert "Task completed" in text_events(events)
    end
  end

  # ====================================================================
  # 3. Tool called exactly once (core parity assertion)
  #    (test_functions_long_running.py: assert function_called == 1)
  # ====================================================================

  describe "tool invocation count" do
    test "long-running tool is called exactly once even through runner loop" do
      counter = :counters.new(1, [:atomics])

      tool =
        LongRunningTool.new(:counted_tool,
          description: "Counted tool",
          func: fn _ctx, %{"x" => x}, _send_update ->
            :counters.add(counter, 1, 1)
            x + 1
          end,
          parameters: %{
            type: "object",
            properties: %{x: %{type: "integer"}}
          },
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "counted_tool", args: %{"x" => 1}, id: "fc-1"}},
        "Got it"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      run_agent(agent, "compute")

      # Core parity assertion: function called exactly once
      assert :counters.get(counter, 1) == 1
    end
  end

  # ====================================================================
  # 4. Non-map return wrapping
  #    (test_functions_long_running.py :: test_async_function_with_none_response)
  #    Python: tool returns string 'pending' → wrapped as {'result': 'pending'}
  #    Elixir: same wrapping via wrap_tool_response
  # ====================================================================

  describe "non-map return value wrapping" do
    test "string return is wrapped in result map" do
      tool =
        LongRunningTool.new(:string_tool,
          description: "Returns a string",
          func: fn _ctx, _args, _send_update ->
            "pending"
          end,
          parameters: %{},
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "string_tool", args: %{}, id: "fc-1"}},
        "Acknowledged"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      events = run_agent(agent, "start")

      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      # String gets wrapped as %{"result" => "pending"} by wrap_tool_response
      assert response == %{"result" => "pending"}
    end

    test "integer return is wrapped in result map" do
      tool =
        LongRunningTool.new(:int_tool,
          description: "Returns an integer",
          func: fn _ctx, %{"x" => x}, _send_update ->
            x * 2
          end,
          parameters: %{
            type: "object",
            properties: %{x: %{type: "integer"}}
          },
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "int_tool", args: %{"x" => 5}, id: "fc-1"}},
        "Result is 10"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      events = run_agent(agent, "double 5")

      frs = collect_fr_responses(events)
      response = get_fr_response(hd(frs))
      assert response == %{"result" => 10}
    end
  end

  # ====================================================================
  # 5. Error handling through runner
  #    Verify errors from long-running tools flow correctly
  # ====================================================================

  describe "error handling through runner" do
    test "tool error is captured in function response" do
      tool =
        LongRunningTool.new(:failing_tool,
          description: "A tool that fails",
          func: fn _ctx, _args, _send_update ->
            raise "something went wrong"
          end,
          parameters: %{},
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "failing_tool", args: %{}, id: "fc-1"}},
        "The tool encountered an error"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      events = run_agent(agent, "fail please")

      # Should have a function response with the error
      assert length(function_response_events(events)) == 1

      # LLM still produces a response after the error
      assert "The tool encountered an error" in text_events(events)
    end

    test "tool timeout is captured in function response" do
      tool =
        LongRunningTool.new(:timeout_tool,
          description: "A tool that times out",
          func: fn _ctx, _args, _send_update ->
            Process.sleep(10_000)
            "never"
          end,
          parameters: %{},
          timeout: 50
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "timeout_tool", args: %{}, id: "fc-1"}},
        "Tool timed out"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tool.",
          tools: [tool]
        )

      events = run_agent(agent, "run slow tool")

      # Function response exists with error
      assert length(function_response_events(events)) == 1

      # LLM responds after timeout
      assert "Tool timed out" in text_events(events)
    end
  end

  # ====================================================================
  # 6. Multiple long-running tools in one agent
  # ====================================================================

  describe "multiple long-running tools" do
    test "two long-running tools called in parallel both complete" do
      counter_a = :counters.new(1, [:atomics])
      counter_b = :counters.new(1, [:atomics])

      tool_a =
        LongRunningTool.new(:task_a,
          description: "Task A",
          func: fn _ctx, _args, send_update ->
            :counters.add(counter_a, 1, 1)
            send_update.("A working...")
            Process.sleep(20)
            "A done"
          end,
          parameters: %{},
          timeout: 5_000
        )

      tool_b =
        LongRunningTool.new(:task_b,
          description: "Task B",
          func: fn _ctx, _args, send_update ->
            :counters.add(counter_b, 1, 1)
            send_update.("B working...")
            Process.sleep(20)
            "B done"
          end,
          parameters: %{},
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "task_a", args: %{}, id: "fc-1"}},
              %{function_call: %{name: "task_b", args: %{}, id: "fc-2"}}
            ]
          },
          usage_metadata: nil
        },
        "Both tasks completed"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tools.",
          tools: [tool_a, tool_b]
        )

      events = run_agent(agent, "run both tasks")

      # Each tool called exactly once
      assert :counters.get(counter_a, 1) == 1
      assert :counters.get(counter_b, 1) == 1

      # Both responses present
      frs = collect_fr_responses(events)
      assert length(frs) == 2

      assert "Both tasks completed" in text_events(events)
    end
  end

  # ====================================================================
  # 7. LongRunningTool description annotation through runner
  #    (test_functions_long_running.py: tool description includes notice)
  # ====================================================================

  describe "tool declaration annotation" do
    test "long-running tool description includes the do-not-call-again notice" do
      tool =
        LongRunningTool.new(:annotated_tool,
          description: "Fetch remote data",
          func: fn _ctx, _args, _send_update -> "data" end,
          parameters: %{}
        )

      decl = ADK.Tool.declaration(tool)
      assert String.contains?(decl.description, "Fetch remote data")
      assert String.contains?(decl.description, "long-running operation")
      assert String.contains?(decl.description, "Do not call this tool again")
    end

    test "tool with no description still gets the notice" do
      tool =
        LongRunningTool.new(:bare_tool,
          func: fn _ctx, _args, _send_update -> "ok" end,
          parameters: %{}
        )

      decl = ADK.Tool.declaration(tool)
      assert String.contains?(decl.description, "long-running operation")
    end
  end

  # ====================================================================
  # 8. Mixed regular + long-running tools in one agent
  # ====================================================================

  describe "mixed tool types" do
    test "regular FunctionTool and LongRunningTool coexist in one agent" do
      counter_fn = :counters.new(1, [:atomics])
      counter_lr = :counters.new(1, [:atomics])

      regular_tool =
        ADK.Tool.FunctionTool.new(:quick_fn,
          description: "Quick function",
          func: fn _ctx, %{"x" => x} ->
            :counters.add(counter_fn, 1, 1)
            {:ok, x + 1}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      lr_tool =
        LongRunningTool.new(:slow_fn,
          description: "Slow function",
          func: fn _ctx, %{"y" => y}, send_update ->
            :counters.add(counter_lr, 1, 1)
            send_update.("Working on #{y}...")
            y * 2
          end,
          parameters: %{type: "object", properties: %{y: %{type: "integer"}}},
          timeout: 5_000
        )

      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "quick_fn", args: %{"x" => 3}, id: "fc-1"}},
              %{function_call: %{name: "slow_fn", args: %{"y" => 5}, id: "fc-2"}}
            ]
          },
          usage_metadata: nil
        },
        "Quick: 4, Slow: 10"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use the tools.",
          tools: [regular_tool, lr_tool]
        )

      events = run_agent(agent, "compute both")

      assert :counters.get(counter_fn, 1) == 1
      assert :counters.get(counter_lr, 1) == 1

      frs = collect_fr_responses(events)
      assert length(frs) == 2

      assert "Quick: 4, Slow: 10" in text_events(events)
    end
  end
end
