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

defmodule ADK.Flows.LlmFlows.FunctionsSequentialParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_functions_sequential.py`.

  Focuses on sequential (one-at-a-time) function call patterns:

  - Sequential tool calls: LLM returns one function_call per response,
    tool executes, result feeds back, LLM calls another tool, repeat
  - Tool invocation count matches the number of sequential calls
  - Each sequential call produces a function_call event followed by
    a function_response event before the next call
  - State threading between sequential calls (tool output influences next call)
  - Conversation history accumulates across sequential rounds

  Python-only tests NOT ported (and why):
  - `mockModel.requests` inspection — Elixir's ADK.LLM.Mock does not
    track request history; conversation accumulation is tested indirectly
    via tool argument progression and call ordering
  """

  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Runner
  alias ADK.Tool.FunctionTool

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp run_agent(agent, message) do
    runner = Runner.new(app_name: "fn_seq_test", agent: agent)
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

  defp get_function_call(part) do
    Map.get(part, :function_call) || Map.get(part, "function_call")
  end

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
  # 1. Three sequential tool calls
  #    (test_functions_sequential.py :: test_sequential_calls)
  #
  #    Python test: LLM returns function_call(x=1), then function_call(x=2),
  #    then function_call(x=3), then text. Each is a separate LLM response.
  #    Tool is called 3 times total, each producing x+1.
  # ====================================================================

  describe "sequential calls (parity: test_sequential_calls)" do
    test "three sequential function calls each execute one at a time" do
      counter = :counters.new(1, [:atomics])
      call_log = :ets.new(:seq_call_log, [:ordered_set, :public])

      tool =
        FunctionTool.new(:increase_by_one,
          description: "Increment x by one",
          func: fn _ctx, %{"x" => x} ->
            idx = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)
            :ets.insert(call_log, {idx, x})
            {:ok, %{"result" => x + 1}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      # Each LLM response is a single function_call, followed by final text
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "increase_by_one", args: %{"x" => 1}, id: "fc-1"}},
        %{function_call: %{name: "increase_by_one", args: %{"x" => 2}, id: "fc-2"}},
        %{function_call: %{name: "increase_by_one", args: %{"x" => 3}, id: "fc-3"}},
        "response1"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "test")

      # Tool was called exactly 3 times
      assert :counters.get(counter, 1) == 3

      # Calls happened in order with correct args
      calls = :ets.tab2list(call_log) |> Enum.sort_by(&elem(&1, 0))
      :ets.delete(call_log)
      assert [{0, 1}, {1, 2}, {2, 3}] == calls

      # 3 function_call events (one per sequential call)
      fc_events = function_call_events(events)
      assert length(fc_events) == 3

      # 3 function_response events (one per sequential call)
      fr_events = function_response_events(events)
      assert length(fr_events) == 3

      # Each response contains x+1
      frs = collect_fr_responses(events)
      results = Enum.map(frs, fn fr -> get_fr_response(fr)["result"] end)
      assert results == [2, 3, 4]

      # Final text response
      assert "response1" in text_events(events)
    end

    test "sequential calls interleave function_call and function_response events" do
      tool =
        FunctionTool.new(:increase_by_one,
          description: "Increment x by one",
          func: fn _ctx, %{"x" => x} ->
            {:ok, %{"result" => x + 1}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "increase_by_one", args: %{"x" => 1}, id: "fc-1"}},
        %{function_call: %{name: "increase_by_one", args: %{"x" => 2}, id: "fc-2"}},
        "done"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "test")

      # Extract event types in order (fc = function_call, fr = function_response, text)
      event_types =
        events
        |> Enum.map(fn e ->
          parts = get_parts(e)

          cond do
            Enum.any?(parts, &(get_function_call(&1) != nil)) -> :fc
            Enum.any?(parts, &(get_function_response(&1) != nil)) -> :fr
            extract_text(e) != nil and extract_text(e) != "" -> :text
            true -> :other
          end
        end)
        |> Enum.filter(&(&1 != :other))

      # Pattern should be: fc, fr, fc, fr, text
      assert event_types == [:fc, :fr, :fc, :fr, :text]
    end
  end

  # ====================================================================
  # 2. Single sequential call (degenerate case)
  #    Ensures sequential handling works for just one call
  # ====================================================================

  describe "single sequential call" do
    test "single function call followed by text response" do
      counter = :counters.new(1, [:atomics])

      tool =
        FunctionTool.new(:increase_by_one,
          description: "Increment x by one",
          func: fn _ctx, %{"x" => x} ->
            :counters.add(counter, 1, 1)
            {:ok, %{"result" => x + 1}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "increase_by_one", args: %{"x" => 5}, id: "fc-1"}},
        "The answer is 6"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "increment 5")

      assert :counters.get(counter, 1) == 1
      assert length(function_call_events(events)) == 1
      assert length(function_response_events(events)) == 1

      frs = collect_fr_responses(events)
      assert length(frs) == 1
      assert get_fr_response(hd(frs))["result"] == 6

      assert "The answer is 6" in text_events(events)
    end
  end

  # ====================================================================
  # 3. Sequential calls with different tools
  #    LLM chains calls to different tools in sequence
  # ====================================================================

  describe "sequential calls with different tools" do
    test "LLM chains calls to different tools sequentially" do
      call_order = :ets.new(:call_order, [:ordered_set, :public])
      seq = :counters.new(1, [:atomics])

      tool_add =
        FunctionTool.new(:add,
          description: "Add two numbers",
          func: fn _ctx, %{"a" => a, "b" => b} ->
            idx = :counters.get(seq, 1)
            :counters.add(seq, 1, 1)
            :ets.insert(call_order, {idx, :add, a + b})
            {:ok, %{"result" => a + b}}
          end,
          parameters: %{
            type: "object",
            properties: %{a: %{type: "integer"}, b: %{type: "integer"}}
          }
        )

      tool_multiply =
        FunctionTool.new(:multiply,
          description: "Multiply two numbers",
          func: fn _ctx, %{"a" => a, "b" => b} ->
            idx = :counters.get(seq, 1)
            :counters.add(seq, 1, 1)
            :ets.insert(call_order, {idx, :multiply, a * b})
            {:ok, %{"result" => a * b}}
          end,
          parameters: %{
            type: "object",
            properties: %{a: %{type: "integer"}, b: %{type: "integer"}}
          }
        )

      tool_negate =
        FunctionTool.new(:negate,
          description: "Negate a number",
          func: fn _ctx, %{"x" => x} ->
            idx = :counters.get(seq, 1)
            :counters.add(seq, 1, 1)
            :ets.insert(call_order, {idx, :negate, -x})
            {:ok, %{"result" => -x}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      # Sequential: add(3,4)=7, multiply(7,2)=14, negate(14)=-14
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "add", args: %{"a" => 3, "b" => 4}, id: "fc-1"}},
        %{function_call: %{name: "multiply", args: %{"a" => 7, "b" => 2}, id: "fc-2"}},
        %{function_call: %{name: "negate", args: %{"x" => 14}, id: "fc-3"}},
        "The final answer is -14"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool_add, tool_multiply, tool_negate]
        )

      events = run_agent(agent, "compute (3+4)*2 then negate")

      # All three tools called in order
      calls = :ets.tab2list(call_order) |> Enum.sort_by(&elem(&1, 0))
      :ets.delete(call_order)

      assert [{0, :add, 7}, {1, :multiply, 14}, {2, :negate, -14}] == calls

      # 3 function_call events, 3 function_response events
      assert length(function_call_events(events)) == 3
      assert length(function_response_events(events)) == 3

      # Results in order
      frs = collect_fr_responses(events)
      results = Enum.map(frs, fn fr -> get_fr_response(fr)["result"] end)
      assert results == [7, 14, -14]

      assert "The final answer is -14" in text_events(events)
    end
  end

  # ====================================================================
  # 4. Sequential calls with state threading via session
  #    Tool writes to session state; next tool reads it
  # ====================================================================

  describe "state threading between sequential calls" do
    test "state set by first tool is readable by second tool via session" do
      results_log = :ets.new(:results_log, [:ordered_set, :public])
      seq = :counters.new(1, [:atomics])

      tool_set =
        FunctionTool.new(:set_value,
          description: "Set a value in session state",
          func: fn ctx, %{"key" => key, "value" => value} ->
            idx = :counters.get(seq, 1)
            :counters.add(seq, 1, 1)
            {:ok, _tc} = ADK.ToolContext.put_state(ctx, key, value)
            :ets.insert(results_log, {idx, :set, key, value})
            {:ok, %{"stored" => true}}
          end,
          parameters: %{
            type: "object",
            properties: %{key: %{type: "string"}, value: %{type: "string"}}
          }
        )

      tool_get =
        FunctionTool.new(:get_value,
          description: "Get a value from session state",
          func: fn ctx, %{"key" => key} ->
            idx = :counters.get(seq, 1)
            :counters.add(seq, 1, 1)
            value = ADK.ToolContext.get_state(ctx, key)
            :ets.insert(results_log, {idx, :get, key, value})
            {:ok, %{"value" => value}}
          end,
          parameters: %{
            type: "object",
            properties: %{key: %{type: "string"}}
          }
        )

      # Sequential: set "color" = "blue", then get "color"
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{
            name: "set_value",
            args: %{"key" => "color", "value" => "blue"},
            id: "fc-1"
          }
        },
        %{function_call: %{name: "get_value", args: %{"key" => "color"}, id: "fc-2"}},
        "The color is blue"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool_set, tool_get]
        )

      events = run_agent(agent, "set color to blue then read it")

      logs = :ets.tab2list(results_log) |> Enum.sort_by(&elem(&1, 0))
      :ets.delete(results_log)

      # First call set "color" to "blue"
      assert {0, :set, "color", "blue"} in logs

      # Second call read "color" and got "blue"
      assert {1, :get, "color", "blue"} in logs

      # Verify function response for the get call contains the value
      frs = collect_fr_responses(events)
      assert length(frs) == 2

      get_response = Enum.at(frs, 1) |> get_fr_response()
      assert get_response["value"] == "blue"

      assert "The color is blue" in text_events(events)
    end
  end

  # ====================================================================
  # 5. Many sequential calls (stress test)
  #    Ensures the runner doesn't break with many sequential rounds
  # ====================================================================

  describe "many sequential calls" do
    test "five sequential calls all execute correctly" do
      counter = :counters.new(1, [:atomics])

      tool =
        FunctionTool.new(:step,
          description: "Execute a step",
          func: fn _ctx, %{"n" => n} ->
            :counters.add(counter, 1, 1)
            {:ok, %{"completed" => n}}
          end,
          parameters: %{type: "object", properties: %{n: %{type: "integer"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "step", args: %{"n" => 1}, id: "fc-1"}},
        %{function_call: %{name: "step", args: %{"n" => 2}, id: "fc-2"}},
        %{function_call: %{name: "step", args: %{"n" => 3}, id: "fc-3"}},
        %{function_call: %{name: "step", args: %{"n" => 4}, id: "fc-4"}},
        %{function_call: %{name: "step", args: %{"n" => 5}, id: "fc-5"}},
        "All 5 steps completed"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "run 5 steps")

      assert :counters.get(counter, 1) == 5
      assert length(function_call_events(events)) == 5
      assert length(function_response_events(events)) == 5

      frs = collect_fr_responses(events)
      completed = Enum.map(frs, fn fr -> get_fr_response(fr)["completed"] end)
      assert completed == [1, 2, 3, 4, 5]

      assert "All 5 steps completed" in text_events(events)
    end
  end

  # ====================================================================
  # 6. Sequential calls where tool result influences next call args
  #    (Demonstrates the chaining pattern from the Python test where
  #     each call uses incrementing x values)
  # ====================================================================

  describe "chained sequential calls with accumulating results" do
    test "tool results feed into subsequent LLM decisions" do
      # Simulates a chain: double(2)=4, double(4)=8, double(8)=16
      call_log = :ets.new(:chain_log, [:bag, :public])

      tool =
        FunctionTool.new(:double,
          description: "Double the input",
          func: fn _ctx, %{"x" => x} ->
            :ets.insert(call_log, {:called, x})
            {:ok, %{"result" => x * 2}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "double", args: %{"x" => 2}, id: "fc-1"}},
        %{function_call: %{name: "double", args: %{"x" => 4}, id: "fc-2"}},
        %{function_call: %{name: "double", args: %{"x" => 8}, id: "fc-3"}},
        "Final result is 16"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "keep doubling from 2")

      calls = :ets.tab2list(call_log)
      :ets.delete(call_log)

      # All three calls happened with correct args
      assert {:called, 2} in calls
      assert {:called, 4} in calls
      assert {:called, 8} in calls
      assert length(calls) == 3

      # Results are 4, 8, 16
      frs = collect_fr_responses(events)
      results = Enum.map(frs, fn fr -> get_fr_response(fr)["result"] end)
      assert results == [4, 8, 16]

      assert "Final result is 16" in text_events(events)
    end
  end

  # ====================================================================
  # 7. Sequential followed by parallel (mixed pattern)
  #    Ensures both modes work in the same conversation
  # ====================================================================

  describe "mixed sequential and parallel" do
    test "sequential call followed by parallel calls in the same conversation" do
      counter = :counters.new(1, [:atomics])

      tool =
        FunctionTool.new(:compute,
          description: "Compute on input",
          func: fn _ctx, %{"x" => x} ->
            :counters.add(counter, 1, 1)
            {:ok, %{"result" => x * 10}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      ADK.LLM.Mock.set_responses([
        # Round 1: single sequential call
        %{function_call: %{name: "compute", args: %{"x" => 1}, id: "fc-1"}},
        # Round 2: two parallel calls
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "compute", args: %{"x" => 2}, id: "fc-2"}},
              %{function_call: %{name: "compute", args: %{"x" => 3}, id: "fc-3"}}
            ]
          },
          usage_metadata: nil
        },
        "Mixed pattern complete"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "compute mixed")

      # 3 total invocations
      assert :counters.get(counter, 1) == 3

      # All results present
      frs = collect_fr_responses(events)
      results = Enum.map(frs, fn fr -> get_fr_response(fr)["result"] end) |> Enum.sort()
      assert results == [10, 20, 30]

      assert "Mixed pattern complete" in text_events(events)
    end
  end

  # ====================================================================
  # 8. Sequential call with tool returning error mid-chain
  #    Ensures the chain continues after an error response
  # ====================================================================

  describe "error in sequential chain" do
    test "tool error mid-chain feeds back to LLM and chain continues" do
      counter = :counters.new(1, [:atomics])

      tool =
        FunctionTool.new(:maybe_fail,
          description: "Might fail based on input",
          func: fn _ctx, %{"x" => x} ->
            :counters.add(counter, 1, 1)

            if x == 0 do
              {:error, "division by zero"}
            else
              {:ok, %{"result" => 100 / x}}
            end
          end,
          parameters: %{type: "object", properties: %{x: %{type: "number"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "maybe_fail", args: %{"x" => 10}, id: "fc-1"}},
        %{function_call: %{name: "maybe_fail", args: %{"x" => 0}, id: "fc-2"}},
        %{function_call: %{name: "maybe_fail", args: %{"x" => 5}, id: "fc-3"}},
        "Handled the error and continued"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "divide 100 by each")

      # All 3 calls were made (including the failing one)
      assert :counters.get(counter, 1) == 3

      # 3 function responses (including error)
      frs = collect_fr_responses(events)
      assert length(frs) == 3

      # First result: 10.0
      first = get_fr_response(Enum.at(frs, 0))
      assert first["result"] == 10.0

      # Third result: 20.0
      third = get_fr_response(Enum.at(frs, 2))
      assert third["result"] == 20.0

      # Final text
      assert "Handled the error and continued" in text_events(events)
    end
  end
end
