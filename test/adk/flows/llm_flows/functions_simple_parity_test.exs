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

defmodule ADK.Flows.LlmFlows.FunctionsSimpleParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_functions_simple.py`.

  Focuses on simple function call patterns not already covered in
  `test/adk/flows/tools_parity_test.exs`:

  - FunctionTool MF/MFA wrapper through full runner pipeline
  - Multiple (3+) parallel tool calls with response matching
  - Tool argument type fidelity (nested maps, lists)
  - Tool return type variety (boolean, list, nested map)
  - Mixed tool types (anonymous fn, MF tuple, MFA tuple) in one agent
  - Tool with no parameters / empty args through runner

  Python-only tests NOT ported (and why):
  - `test_function_call_args_not_modified` / deep copy — Elixir data is immutable
  - `test_parallel_execution_timing` — Python asyncio-specific (BEAM scheduling differs)
  - `test_sync_function_blocks_async_functions` — Python GIL/event-loop concern
  - `test_computer_use_tool_decoding_behavior` — Python-specific screenshot handling
  - `find_matching_function_call` / `merge_parallel_function_response_events` — Python internals
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
    runner = Runner.new(app_name: "fn_simple_test", agent: agent)
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
      Enum.any?(parts, &(Map.has_key?(&1, :function_response) or Map.has_key?(&1, "function_response")))
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

  # Extract all function_response parts from response events
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
  # 1. FunctionTool MF tuple through full runner pipeline
  #    (test_functions_simple.py :: test_function_tool — MF variant)
  # ====================================================================

  describe "FunctionTool MF/MFA through runner" do
    test "MF tuple tool executes correctly through full runner pipeline" do
      tool =
        FunctionTool.new(:greet,
          description: "Greet someone",
          func: {__MODULE__.ToolFns, :greet},
          parameters: %{type: "object", properties: %{name: %{type: "string"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "greet", args: %{"name" => "Ada"}, id: "fc-1"}},
        "Greeting sent"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "greet Ada")

      assert length(function_call_events(events)) == 1
      assert length(function_response_events(events)) == 1

      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      assert response == %{"result" => "Hello, Ada!"}
      assert "Greeting sent" in text_events(events)
    end

    test "MFA tuple tool with extra args executes through runner" do
      tool =
        FunctionTool.new(:greet_formal,
          description: "Greet someone formally",
          func: {__MODULE__.ToolFns, :greet_with_prefix, ["Dr."]},
          parameters: %{type: "object", properties: %{name: %{type: "string"}}}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "greet_formal", args: %{"name" => "Turing"}, id: "fc-1"}},
        "Formal greeting sent"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "greet Dr. Turing")

      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      assert response == %{"result" => "Hello, Dr. Turing!"}
      assert "Formal greeting sent" in text_events(events)
    end
  end

  # ====================================================================
  # 2. Multiple (3+) parallel tool calls
  #    (test_functions_simple.py :: test_async_function — 3 parallel calls)
  # ====================================================================

  describe "triple parallel tool calls" do
    test "three tool calls in one LLM response all execute and return results" do
      test_pid = self()

      tool_inc =
        FunctionTool.new(:increase_by_one,
          description: "Increment x",
          func: fn _ctx, %{"x" => x} ->
            send(test_pid, {:inc, x})
            {:ok, %{"result" => x + 1}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      tool_double =
        FunctionTool.new(:multiply_by_two,
          description: "Double x",
          func: fn _ctx, %{"x" => x} ->
            send(test_pid, {:double, x})
            {:ok, %{"result" => x * 2}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      tool_square =
        FunctionTool.new(:square,
          description: "Square x",
          func: fn _ctx, %{"x" => x} ->
            send(test_pid, {:square, x})
            {:ok, %{"result" => x * x}}
          end,
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        )

      # Three parallel function calls in one response
      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "increase_by_one", args: %{"x" => 5}, id: "fc-1"}},
              %{function_call: %{name: "multiply_by_two", args: %{"x" => 3}, id: "fc-2"}},
              %{function_call: %{name: "square", args: %{"x" => 4}, id: "fc-3"}}
            ]
          },
          usage_metadata: nil
        },
        "Results: 6, 6, 16"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool_inc, tool_double, tool_square]
        )

      events = run_agent(agent, "compute all")

      # All three tools called
      assert_received {:inc, 5}
      assert_received {:double, 3}
      assert_received {:square, 4}

      # One call event (with 3 parts), one response event (with 3 parts)
      assert length(function_call_events(events)) == 1
      assert length(function_response_events(events)) == 1

      # Response event has 3 function_response parts
      [resp_event] = function_response_events(events)
      fr_parts = get_parts(resp_event) |> Enum.filter(&get_function_response/1)
      assert length(fr_parts) == 3

      # Verify result values
      responses =
        fr_parts
        |> Enum.map(fn p -> get_fr_response(get_function_response(p)) end)
        |> Enum.map(fn r -> r["result"] end)
        |> Enum.sort()

      assert responses == [6, 6, 16]

      assert "Results: 6, 6, 16" in text_events(events)
    end
  end

  # ====================================================================
  # 3. Tool argument type fidelity
  #    (test_functions_simple.py :: test_function_call_args_copy_behavior)
  #    In Elixir we verify args arrive intact (no mutation concern)
  # ====================================================================

  describe "argument type fidelity" do
    test "nested map arguments are passed faithfully to the tool" do
      test_pid = self()

      tool =
        FunctionTool.new(:process_data,
          description: "Process nested data",
          func: fn _ctx, args ->
            send(test_pid, {:args, args})
            {:ok, %{"processed" => true}}
          end,
          parameters: %{
            type: "object",
            properties: %{
              config: %{type: "object"},
              tags: %{type: "array", items: %{type: "string"}}
            }
          }
        )

      nested_args = %{
        "config" => %{"inner" => %{"value" => "original", "count" => 42}},
        "tags" => ["alpha", "beta", "gamma"]
      }

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "process_data", args: nested_args, id: "fc-1"}},
        "Processed"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      run_agent(agent, "process")

      assert_received {:args, received_args}
      assert received_args["config"]["inner"]["value"] == "original"
      assert received_args["config"]["inner"]["count"] == 42
      assert received_args["tags"] == ["alpha", "beta", "gamma"]
    end

    test "empty args map is passed when LLM sends empty args" do
      test_pid = self()

      tool =
        FunctionTool.new(:ping,
          description: "Ping",
          func: fn _ctx, args ->
            send(test_pid, {:args, args})
            {:ok, "pong"}
          end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "ping", args: %{}, id: "fc-1"}},
        "Ponged"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      run_agent(agent, "ping")

      assert_received {:args, received}
      assert received == %{}
    end
  end

  # ====================================================================
  # 4. Tool return type variety
  #    (test_functions_simple.py patterns — various return types)
  # ====================================================================

  describe "return type variety" do
    test "tool returning boolean is wrapped in response" do
      tool =
        FunctionTool.new(:check,
          description: "Check condition",
          func: fn _ctx, _args -> {:ok, true} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "check", args: %{}, id: "fc-1"}},
        "Check passed"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "check it")
      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      assert response == %{"result" => true}
    end

    test "tool returning a list is wrapped in response" do
      tool =
        FunctionTool.new(:get_items,
          description: "Get items",
          func: fn _ctx, _args -> {:ok, ["a", "b", "c"]} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "get_items", args: %{}, id: "fc-1"}},
        "Got items"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "list items")
      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      assert response == %{"result" => ["a", "b", "c"]}
    end

    test "tool returning a nested map preserves structure" do
      tool =
        FunctionTool.new(:get_nested,
          description: "Get nested data",
          func: fn _ctx, _args ->
            {:ok, %{"user" => %{"name" => "Alice", "scores" => [90, 95, 88]}}}
          end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "get_nested", args: %{}, id: "fc-1"}},
        "Got nested"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "get data")
      frs = collect_fr_responses(events)
      assert length(frs) == 1
      response = get_fr_response(hd(frs))
      assert response == %{"user" => %{"name" => "Alice", "scores" => [90, 95, 88]}}
    end

    test "tool returning nil results in response" do
      tool =
        FunctionTool.new(:void_op,
          description: "No return value",
          func: fn _ctx, _args -> {:ok, nil} end,
          parameters: %{}
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "void_op", args: %{}, id: "fc-1"}},
        "Void completed"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      events = run_agent(agent, "do nothing")

      # Should not crash; should still produce function_response
      assert length(function_response_events(events)) == 1
      assert "Void completed" in text_events(events)
    end
  end

  # ====================================================================
  # 5. Mixed tool types in one agent
  #    (test_functions_simple.py :: test_function_tool — mixed wrapped/bare)
  # ====================================================================

  describe "mixed tool types" do
    test "anonymous fn, MF tuple, and MFA tuple tools all work in one agent" do
      test_pid = self()

      anon_tool =
        FunctionTool.new(:anon_add,
          description: "Add via anonymous fn",
          func: fn _ctx, %{"a" => a, "b" => b} ->
            send(test_pid, {:anon, a + b})
            {:ok, %{"result" => a + b}}
          end,
          parameters: %{type: "object", properties: %{a: %{type: "integer"}, b: %{type: "integer"}}}
        )

      mf_tool =
        FunctionTool.new(:mf_greet,
          description: "Greet via MF tuple",
          func: {__MODULE__.ToolFns, :greet},
          parameters: %{type: "object", properties: %{name: %{type: "string"}}}
        )

      mfa_tool =
        FunctionTool.new(:mfa_greet,
          description: "Greet via MFA tuple",
          func: {__MODULE__.ToolFns, :greet_with_prefix, ["Prof."]},
          parameters: %{type: "object", properties: %{name: %{type: "string"}}}
        )

      # Call all three tools in parallel
      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "anon_add", args: %{"a" => 10, "b" => 20}, id: "fc-1"}},
              %{function_call: %{name: "mf_greet", args: %{"name" => "Lovelace"}, id: "fc-2"}},
              %{function_call: %{name: "mfa_greet", args: %{"name" => "Knuth"}, id: "fc-3"}}
            ]
          },
          usage_metadata: nil
        },
        "All tools worked"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [anon_tool, mf_tool, mfa_tool]
        )

      events = run_agent(agent, "do all")

      assert_received {:anon, 30}

      # All 3 responses present
      frs = collect_fr_responses(events)
      assert length(frs) == 3

      responses =
        frs
        |> Enum.map(&get_fr_response/1)
        |> Enum.map(fn r -> r["result"] end)
        |> Enum.sort()

      assert "Hello, Lovelace!" in responses
      assert "Hello, Prof. Knuth!" in responses
      assert 30 in responses

      assert "All tools worked" in text_events(events)
    end
  end

  # ====================================================================
  # 6. Tool declaration is correct for LLM
  #    (test_functions_simple.py — tool declarations sent to model)
  # ====================================================================

  describe "tool declarations" do
    test "FunctionTool declaration includes name, description, and parameters" do
      tool =
        FunctionTool.new(:search,
          description: "Search the web",
          func: fn _ctx, _args -> {:ok, []} end,
          parameters: %{
            type: "object",
            properties: %{
              query: %{type: "string", description: "Search query"},
              limit: %{type: "integer", description: "Max results"}
            },
            required: ["query"]
          }
        )

      decl = ADK.Tool.declaration(tool)
      assert decl.name == "search"
      assert decl.description == "Search the web"
      assert decl.parameters.type == "object"
      assert Map.has_key?(decl.parameters.properties, :query)
      assert decl.parameters.required == ["query"]
    end

    test "FunctionTool with no parameters produces empty params in declaration" do
      tool =
        FunctionTool.new(:noop,
          description: "Do nothing",
          func: fn _ctx, _args -> {:ok, nil} end
        )

      decl = ADK.Tool.declaration(tool)
      assert decl.name == "noop"
      assert decl.description == "Do nothing"
      assert decl.parameters == %{}
    end
  end

  # ====================================================================
  # 7. Tool called exactly once per function_call
  #    (test_functions_simple.py :: test_simple_function — assert function_called == 1)
  # ====================================================================

  describe "exact call count" do
    test "tool is called exactly once for a single function_call" do
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

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "inc", args: %{"x" => 1}, id: "fc-1"}},
        "Result is 2"
      ])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Use tools.",
          tools: [tool]
        )

      run_agent(agent, "increment 1")
      assert :counters.get(counter, 1) == 1
    end

    test "three parallel calls invoke each tool exactly once" do
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
        "All done"
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
  end

  # ====================================================================
  # Helper module for MF/MFA tool tests
  # ====================================================================

  defmodule ToolFns do
    @moduledoc false

    def greet(_ctx, %{"name" => name}) do
      {:ok, %{"result" => "Hello, #{name}!"}}
    end

    def greet_with_prefix(_ctx, %{"name" => name}, prefix) do
      {:ok, %{"result" => "Hello, #{prefix} #{name}!"}}
    end
  end
end
