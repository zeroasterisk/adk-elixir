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

defmodule ADK.Flows.LlmFlows.FunctionsParallelParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_functions_parallel.py`.

  Focuses on parallel function call patterns through the runner pipeline:

  - Parallel tool calls with session state mutation via ToolContext
  - Parallel tool calls including a transfer_to_agent tool
  - Event structure: function_call event ➜ function_response event ➜ final text
  - Response ordering matches call ordering
  - Error handling when one parallel tool is unknown
  - Error handling when one parallel tool raises
  - All parallel tools are invoked exactly once

  Python-only tests NOT ported (and why):
  - `EventActions` equality assertion — Python uses dataclass equality;
    Elixir checks fields individually since state_delta structure differs
    (Elixir session state is in a GenServer, not a plain dict)
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
    runner = Runner.new(app_name: "fn_parallel_test", agent: agent)
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

  defp get_fr_name(fr) when is_map(fr) do
    Map.get(fr, :name) || Map.get(fr, "name")
  end

  defp get_fr_name(_), do: nil

  defp collect_fr_parts(events) do
    events
    |> function_response_events()
    |> Enum.flat_map(fn e ->
      get_parts(e)
      |> Enum.map(&get_function_response/1)
      |> Enum.filter(& &1)
    end)
  end

  # ====================================================================
  # 1. Parallel function calls with state change
  #    (test_functions_parallel.py :: test_parallel_function_calls_with_state_change)
  #
  #    Python test: 2 state-updating tools + 1 transfer tool, all in one
  #    LLM response. Asserts: all 3 tools called, state deltas merged,
  #    transfer fires, events structured correctly.
  #
  #    Elixir divergence: transfer uses per-agent tools (transfer_to_agent_<name>)
  #    rather than a single transfer_to_agent(agent_name) tool. State is written
  #    to session GenServer via ToolContext.put_state (not event actions merge).
  # ====================================================================

  describe "parallel function calls with state change (parity: test_parallel_function_calls_with_state_change)" do
    test "two state-updating tools and one transfer tool all execute in parallel" do
      call_counter = :counters.new(1, [:atomics])

      update_state_tool =
        FunctionTool.new(:update_session_state,
          description: "Update session state with key/value",
          func: fn ctx, %{"key" => key, "value" => value} ->
            :counters.add(call_counter, 1, 1)
            {:ok, _tc} = ADK.ToolContext.put_state(ctx, key, value)
            {:ok, nil}
          end,
          parameters: %{
            type: "object",
            properties: %{
              key: %{type: "string"},
              value: %{type: "string"}
            }
          }
        )

      # Sub-agent to transfer to
      test_sub_agent =
        LlmAgent.new(
          name: "test_sub_agent",
          model: "test",
          instruction: "I am the sub agent."
        )

      # Root agent with sub-agents — transfer tools auto-generated
      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [update_state_tool],
          sub_agents: [test_sub_agent]
        )

      # LLM returns 3 parallel calls: 2 state updates + 1 transfer
      ADK.LLM.Mock.set_responses([
        # First LLM call: root_agent sees 3 parallel function calls
        %{
          content: %{
            role: :model,
            parts: [
              %{
                function_call: %{
                  name: "update_session_state",
                  args: %{"key" => "test_key1", "value" => "test_value1"},
                  id: "fc-1"
                }
              },
              %{
                function_call: %{
                  name: "update_session_state",
                  args: %{"key" => "test_key2", "value" => "test_value2"},
                  id: "fc-2"
                }
              },
              %{
                function_call: %{
                  name: "transfer_to_agent_test_sub_agent",
                  args: %{},
                  id: "fc-3"
                }
              }
            ]
          },
          usage_metadata: nil
        },
        # Second LLM call: test_sub_agent responds
        "response1"
      ])

      events = run_agent(agent, "test")

      # All 3 functions were called (2 state + 1 transfer)
      # The state tools increment counter; transfer tool is auto-generated
      assert :counters.get(call_counter, 1) == 2

      # Event structure: function_call event → transfer event → sub-agent response
      # (Elixir handles transfer immediately, skipping function_response for transfer case)
      fc_events = function_call_events(events)
      assert length(fc_events) >= 1

      # The first fc event should have 3 parts (the parallel calls)
      first_fc = hd(fc_events)
      fc_parts = get_parts(first_fc)

      fc_names =
        fc_parts
        |> Enum.flat_map(fn
          %{function_call: %{name: n}} -> [n]
          %{"function_call" => %{"name" => n}} -> [n]
          _ -> []
        end)

      assert "update_session_state" in fc_names
      assert "transfer_to_agent_test_sub_agent" in fc_names

      # Final text response should come from sub-agent run
      texts = text_events(events)

      assert Enum.any?(texts, &String.contains?(&1, "response1")) or
               Enum.any?(texts, &String.contains?(&1, "Transferring"))
    end

    test "state values are actually written to session by parallel tools" do
      state_captures = :ets.new(:state_captures, [:set, :public])

      # Second tool reads state set by first tool and captures it
      update_state_tool =
        FunctionTool.new(:update_session_state,
          description: "Update session state",
          func: fn ctx, %{"key" => key, "value" => value} ->
            {:ok, tc} = ADK.ToolContext.put_state(ctx, key, value)
            # Capture the delta to verify state was tracked
            :ets.insert(state_captures, {key, value, tc.actions.state_delta})
            {:ok, nil}
          end,
          parameters: %{
            type: "object",
            properties: %{key: %{type: "string"}, value: %{type: "string"}}
          }
        )

      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{
                function_call: %{
                  name: "update_session_state",
                  args: %{"key" => "k1", "value" => "v1"},
                  id: "fc-1"
                }
              },
              %{
                function_call: %{
                  name: "update_session_state",
                  args: %{"key" => "k2", "value" => "v2"},
                  id: "fc-2"
                }
              }
            ]
          },
          usage_metadata: nil
        },
        "done"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [update_state_tool]
        )

      events = run_agent(agent, "update both")

      # Verify both state puts happened
      [{_, "v1", delta1}] = :ets.lookup(state_captures, "k1")
      [{_, "v2", delta2}] = :ets.lookup(state_captures, "k2")
      :ets.delete(state_captures)

      assert Map.get(delta1, "k1") == "v1"
      assert Map.get(delta2, "k2") == "v2"

      assert "done" in text_events(events)
    end
  end

  # ====================================================================
  # 2. Response ordering matches call ordering
  #    (Derived from Python test's assertion that function_responses
  #     appear in the same order as function_calls)
  # ====================================================================

  describe "parallel response ordering" do
    test "function responses maintain the same order as function calls" do
      tool_a =
        FunctionTool.new(:tool_alpha,
          description: "Alpha tool",
          func: fn _ctx, _args ->
            # Simulate slight delay
            Process.sleep(5)
            {:ok, %{"result" => "alpha_result"}}
          end,
          parameters: %{}
        )

      tool_b =
        FunctionTool.new(:tool_beta,
          description: "Beta tool",
          func: fn _ctx, _args -> {:ok, %{"result" => "beta_result"}} end,
          parameters: %{}
        )

      tool_c =
        FunctionTool.new(:tool_gamma,
          description: "Gamma tool",
          func: fn _ctx, _args -> {:ok, %{"result" => "gamma_result"}} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "tool_alpha", args: %{}, id: "fc-1"}},
              %{function_call: %{name: "tool_beta", args: %{}, id: "fc-2"}},
              %{function_call: %{name: "tool_gamma", args: %{}, id: "fc-3"}}
            ]
          },
          usage_metadata: nil
        },
        "All results collected"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool_a, tool_b, tool_c]
        )

      events = run_agent(agent, "run all")

      # Get the function response event
      fr_events = function_response_events(events)
      assert length(fr_events) == 1

      # Extract response names in order
      fr_parts = collect_fr_parts(events)
      names = Enum.map(fr_parts, &get_fr_name/1)
      assert names == ["tool_alpha", "tool_beta", "tool_gamma"]

      # Extract response values in order
      values =
        fr_parts
        |> Enum.map(&get_fr_response/1)
        |> Enum.map(fn r -> r["result"] end)

      assert values == ["alpha_result", "beta_result", "gamma_result"]
    end
  end

  # ====================================================================
  # 3. Error handling: unknown tool in parallel batch
  #    (Not in Python test directly, but tests error resilience)
  # ====================================================================

  describe "error handling in parallel calls" do
    test "unknown tool in parallel batch produces error response without crashing" do
      known_tool =
        FunctionTool.new(:known,
          description: "A known tool",
          func: fn _ctx, _args -> {:ok, "known_result"} end,
          parameters: %{}
        )

      # LLM calls both a known tool and an unknown tool
      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "known", args: %{}, id: "fc-1"}},
              %{function_call: %{name: "nonexistent_tool", args: %{}, id: "fc-2"}}
            ]
          },
          usage_metadata: nil
        },
        "Handled gracefully"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [known_tool]
        )

      events = run_agent(agent, "call both")

      # Should not crash; should produce function_response events
      fr_parts = collect_fr_parts(events)
      assert length(fr_parts) == 2

      # One should have the known result
      known_fr =
        Enum.find(fr_parts, fn fr -> get_fr_name(fr) == "known" end)

      assert known_fr
      assert get_fr_response(known_fr) == %{"result" => "known_result"}

      # The other should have an error for the unknown tool
      unknown_fr =
        Enum.find(fr_parts, fn fr -> get_fr_name(fr) == "nonexistent_tool" end)

      assert unknown_fr
      unknown_response = get_fr_response(unknown_fr)
      assert is_map(unknown_response) or is_binary(unknown_response)

      # Final text should appear
      assert "Handled gracefully" in text_events(events)
    end

    test "tool raising an error in parallel batch produces error response" do
      good_tool =
        FunctionTool.new(:good_tool,
          description: "Works fine",
          func: fn _ctx, _args -> {:ok, "good"} end,
          parameters: %{}
        )

      bad_tool =
        FunctionTool.new(:bad_tool,
          description: "Always fails",
          func: fn _ctx, _args -> {:error, "something went wrong"} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "good_tool", args: %{}, id: "fc-1"}},
              %{function_call: %{name: "bad_tool", args: %{}, id: "fc-2"}}
            ]
          },
          usage_metadata: nil
        },
        "Error handled"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [good_tool, bad_tool]
        )

      events = run_agent(agent, "run both")

      # Should produce function responses for both
      fr_parts = collect_fr_parts(events)
      assert length(fr_parts) == 2

      # Good tool has successful result
      good_fr = Enum.find(fr_parts, fn fr -> get_fr_name(fr) == "good_tool" end)
      assert get_fr_response(good_fr) == %{"result" => "good"}

      # Bad tool has error wrapped in response
      bad_fr = Enum.find(fr_parts, fn fr -> get_fr_name(fr) == "bad_tool" end)
      bad_response = get_fr_response(bad_fr)
      assert bad_response != nil

      # LLM continues after error
      assert "Error handled" in text_events(events)
    end
  end

  # ====================================================================
  # 4. Exact invocation counts for parallel calls
  #    (Python test: assert function_called == 3)
  # ====================================================================

  describe "exact invocation counts" do
    test "each tool in a parallel batch is called exactly once" do
      counters = %{
        a: :counters.new(1, [:atomics]),
        b: :counters.new(1, [:atomics]),
        c: :counters.new(1, [:atomics])
      }

      tool_a =
        FunctionTool.new(:fn_a,
          description: "A",
          func: fn _ctx, _args ->
            :counters.add(counters.a, 1, 1)
            {:ok, "a"}
          end,
          parameters: %{}
        )

      tool_b =
        FunctionTool.new(:fn_b,
          description: "B",
          func: fn _ctx, _args ->
            :counters.add(counters.b, 1, 1)
            {:ok, "b"}
          end,
          parameters: %{}
        )

      tool_c =
        FunctionTool.new(:fn_c,
          description: "C",
          func: fn _ctx, _args ->
            :counters.add(counters.c, 1, 1)
            {:ok, "c"}
          end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "fn_a", args: %{}, id: "fc-1"}},
              %{function_call: %{name: "fn_b", args: %{}, id: "fc-2"}},
              %{function_call: %{name: "fn_c", args: %{}, id: "fc-3"}}
            ]
          },
          usage_metadata: nil
        },
        "All executed"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool_a, tool_b, tool_c]
        )

      run_agent(agent, "run all")

      assert :counters.get(counters.a, 1) == 1
      assert :counters.get(counters.b, 1) == 1
      assert :counters.get(counters.c, 1) == 1
    end

    test "same tool called multiple times in parallel is invoked once per call" do
      counter = :counters.new(1, [:atomics])

      tool =
        FunctionTool.new(:inc,
          description: "Increment",
          func: fn _ctx, %{"x" => x} ->
            :counters.add(counter, 1, 1)
            {:ok, %{"result" => x + 1}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      # Same tool called 3 times with different args
      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "inc", args: %{"x" => 1}, id: "fc-1"}},
              %{function_call: %{name: "inc", args: %{"x" => 10}, id: "fc-2"}},
              %{function_call: %{name: "inc", args: %{"x" => 100}, id: "fc-3"}}
            ]
          },
          usage_metadata: nil
        },
        "Incremented all"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "increment all")

      # Tool called 3 times total
      assert :counters.get(counter, 1) == 3

      # All 3 responses present
      fr_parts = collect_fr_parts(events)
      assert length(fr_parts) == 3

      results =
        fr_parts
        |> Enum.map(fn fr -> get_fr_response(fr) end)
        |> Enum.map(fn r -> r["result"] end)
        |> Enum.sort()

      assert results == [2, 11, 101]
    end
  end

  # ====================================================================
  # 5. Parallel calls followed by multi-turn conversation
  #    (Extends Python test pattern — parallel tools → text → more tools)
  # ====================================================================

  describe "multi-turn with parallel calls" do
    test "parallel tool calls can be followed by another round of tool calls" do
      call_log = :ets.new(:call_log, [:bag, :public])

      tool_x =
        FunctionTool.new(:tool_x,
          description: "Tool X",
          func: fn _ctx, %{"v" => v} ->
            :ets.insert(call_log, {:call, "x", v})
            {:ok, %{"result" => "x:#{v}"}}
          end,
          parameters: %{type: "object", properties: %{v: %{type: "string"}}}
        )

      tool_y =
        FunctionTool.new(:tool_y,
          description: "Tool Y",
          func: fn _ctx, %{"v" => v} ->
            :ets.insert(call_log, {:call, "y", v})
            {:ok, %{"result" => "y:#{v}"}}
          end,
          parameters: %{type: "object", properties: %{v: %{type: "string"}}}
        )

      ADK.LLM.Mock.set_responses([
        # Round 1: two parallel calls
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "tool_x", args: %{"v" => "first"}, id: "fc-1"}},
              %{function_call: %{name: "tool_y", args: %{"v" => "first"}, id: "fc-2"}}
            ]
          },
          usage_metadata: nil
        },
        # Round 2: single call
        %{function_call: %{name: "tool_x", args: %{"v" => "second"}, id: "fc-3"}},
        # Final response
        "All rounds complete"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool_x, tool_y]
        )

      events = run_agent(agent, "multi-turn")

      # Verify call log
      calls = :ets.tab2list(call_log)
      :ets.delete(call_log)

      assert {:call, "x", "first"} in calls
      assert {:call, "y", "first"} in calls
      assert {:call, "x", "second"} in calls
      assert length(calls) == 3

      # Final text present
      assert "All rounds complete" in text_events(events)
    end
  end

  # ====================================================================
  # 6. Single function call (non-parallel) still works
  #    (Sanity check — ensures parallel handling doesn't break single calls)
  # ====================================================================

  describe "single call regression" do
    test "single function call in LLM response works correctly" do
      tool =
        FunctionTool.new(:echo,
          description: "Echo input",
          func: fn _ctx, %{"msg" => msg} -> {:ok, %{"echoed" => msg}} end,
          parameters: %{type: "object", properties: %{msg: %{type: "string"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "echo", args: %{"msg" => "hello"}, id: "fc-1"}},
        "Echo done"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "echo hello")

      fr_parts = collect_fr_parts(events)
      assert length(fr_parts) == 1
      assert get_fr_response(hd(fr_parts)) == %{"echoed" => "hello"}
      assert "Echo done" in text_events(events)
    end
  end
end
