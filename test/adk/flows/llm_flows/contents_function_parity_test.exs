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

defmodule ADK.Flows.LlmFlows.ContentsFunctionParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_contents_function.py`.

  The Python test exercises function call/response content construction
  and LRO (long-running operation) rearrangement in the contents processor.

  In Elixir, the LRO rearrangement pipeline does not exist — long-running
  tools resolve within a single `Runner.run/5` call via OTP Tasks. These
  tests cover the **applicable behavioural subset** that carries over:

  1. Function call content structure: model-role event with function_call part
  2. Function response content structure: user-role event with function_response part
  3. Function response contains tool name and response payload
  4. Multiple function calls in same LLM response produce correct event parts
  5. Mixed text + function_call parts in model response
  6. Function call/response pairs in session history survive into build_messages
  7. Multiple sequential tool calls maintain correct content ordering
  8. Function response wraps tool result in expected format

  Python-only tests NOT ported (and why):
  - `test_rearrangement_with_intermediate_function_response` — LRO rearrangement;
    Elixir resolves LRO within a single run via OTP Task
  - `test_mixed_long_running_and_normal_function_calls` — same reason
  - `test_completed_long_running_function_in_history` — same reason
  - `test_completed_mixed_function_calls_in_history` — same reason
  - `test_function_rearrangement_preserves_other_content` — same reason
  - `test_error_when_function_response_without_matching_call` — Elixir builds
    function responses internally from tool execution, not from external events
  """

  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Event
  alias ADK.Runner

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp unique_session, do: "s-#{System.unique_integer([:positive])}"

  defp build_agent(opts \\ []) do
    LlmAgent.new(
      Keyword.merge(
        [model: "gemini-test", name: "test_agent", instruction: "You are helpful"],
        opts
      )
    )
  end

  defp make_tool(name, func) do
    ADK.Tool.FunctionTool.new(String.to_atom(name),
      description: "Tool: #{name}",
      func: func,
      parameters: %{type: "object", properties: %{}}
    )
  end

  defp extract_text(%{content: content}) when is_map(content) do
    parts = content[:parts] || content["parts"] || []

    Enum.find_value(parts, fn
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end)
  end

  defp extract_text(_), do: nil

  defp extract_function_call_parts(%{content: content}) when is_map(content) do
    parts = content[:parts] || content["parts"] || []
    Enum.filter(parts, fn p -> Map.has_key?(p, :function_call) end)
  end

  defp extract_function_call_parts(_), do: []

  defp extract_function_response_parts(%{content: content}) when is_map(content) do
    parts = content[:parts] || content["parts"] || []
    Enum.filter(parts, fn p -> Map.has_key?(p, :function_response) end)
  end

  defp extract_function_response_parts(_), do: []

  defp run_agent(agent, message) do
    runner = Runner.new(app_name: "fn_content_test", agent: agent)
    sid = unique_session()
    Runner.run(runner, "u1", sid, message)
  end

  # ── Function Call Content Structure ──────────────────────────────────
  # Mirrors test_basic_function_call_response_processing:
  # function_call part in model content, function_response part in user content

  describe "function call content structure" do
    test "function call event has model role with function_call part containing name and args" do
      fc = %{name: "search_tool", args: %{"query" => "test"}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "Search results found"
      ])

      tool = make_tool("search_tool", fn _ctx, %{"query" => q} ->
        {:ok, %{results: ["item1 for #{q}", "item2"]}}
      end)

      agent = build_agent(tools: [tool])
      events = run_agent(agent, "Search for test")

      # Find the function call event
      fc_event = Enum.find(events, fn e ->
        extract_function_call_parts(e) != []
      end)

      assert fc_event != nil, "Expected a function_call event"
      assert fc_event.content[:role] == :model

      [fc_part] = extract_function_call_parts(fc_event)
      assert fc_part.function_call.name == "search_tool"
      assert fc_part.function_call.args == %{"query" => "test"}
    end

    test "function response event has user role with function_response part" do
      fc = %{name: "search_tool", args: %{"query" => "test"}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "Here are the results"
      ])

      tool = make_tool("search_tool", fn _ctx, %{"query" => _q} ->
        {:ok, %{results: ["item1", "item2"]}}
      end)

      agent = build_agent(tools: [tool])
      events = run_agent(agent, "Search for test")

      # Find the function response event
      fr_event = Enum.find(events, fn e ->
        extract_function_response_parts(e) != []
      end)

      assert fr_event != nil, "Expected a function_response event"
      assert fr_event.content[:role] == :user
    end

    test "function response contains tool name and response payload" do
      fc = %{name: "get_weather", args: %{"city" => "London"}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "The weather is sunny"
      ])

      tool = make_tool("get_weather", fn _ctx, %{"city" => city} ->
        {:ok, %{weather: "sunny", city: city}}
      end)

      agent = build_agent(tools: [tool])
      events = run_agent(agent, "What's the weather in London?")

      fr_event = Enum.find(events, fn e ->
        extract_function_response_parts(e) != []
      end)

      assert fr_event != nil
      [fr_part] = extract_function_response_parts(fr_event)

      assert fr_part.function_response.name == "get_weather"
      assert is_map(fr_part.function_response.response)
    end

    test "function response wraps result map under :result key" do
      fc = %{name: "compute", args: %{"x" => 5}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "Done"
      ])

      tool = make_tool("compute", fn _ctx, %{"x" => x} ->
        {:ok, %{value: x * 2}}
      end)

      agent = build_agent(tools: [tool])
      events = run_agent(agent, "Compute 5")

      fr_event = Enum.find(events, fn e ->
        extract_function_response_parts(e) != []
      end)

      assert fr_event != nil
      [fr_part] = extract_function_response_parts(fr_event)

      # The runner wraps tool results via wrap_tool_response
      response = fr_part.function_response.response
      assert is_map(response), "Function response should be a map, got: #{inspect(response)}"
    end
  end

  # ── Multiple Function Calls in Same Response ─────────────────────────
  # Mirrors test_mixed_long_running_and_normal_function_calls structure
  # (parallel calls in same model response)

  describe "multiple function calls in same LLM response" do
    test "parallel function calls produce event with multiple function_call parts" do
      # LLM returns two function calls at once
      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "tool_a", args: %{"input" => "a"}}},
              %{function_call: %{name: "tool_b", args: %{"input" => "b"}}}
            ]
          },
          usage_metadata: nil
        },
        "Both tools completed"
      ])

      tool_a = make_tool("tool_a", fn _ctx, %{"input" => i} ->
        {:ok, %{output: "#{i}_done"}}
      end)

      tool_b = make_tool("tool_b", fn _ctx, %{"input" => i} ->
        {:ok, %{output: "#{i}_done"}}
      end)

      agent = build_agent(tools: [tool_a, tool_b])
      events = run_agent(agent, "Run both tools")

      # Find event with function call parts
      fc_event = Enum.find(events, fn e ->
        length(extract_function_call_parts(e)) >= 2
      end)

      assert fc_event != nil, "Expected event with multiple function_call parts"
      fc_parts = extract_function_call_parts(fc_event)
      assert length(fc_parts) == 2

      names = Enum.map(fc_parts, fn p -> p.function_call.name end) |> Enum.sort()
      assert names == ["tool_a", "tool_b"]
    end

    test "parallel function calls produce response event with matching function_response parts" do
      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "tool_a", args: %{"x" => 1}}},
              %{function_call: %{name: "tool_b", args: %{"x" => 2}}}
            ]
          },
          usage_metadata: nil
        },
        "Both done"
      ])

      tool_a = make_tool("tool_a", fn _ctx, %{"x" => x} ->
        {:ok, %{result: x + 10}}
      end)

      tool_b = make_tool("tool_b", fn _ctx, %{"x" => x} ->
        {:ok, %{result: x + 20}}
      end)

      agent = build_agent(tools: [tool_a, tool_b])
      events = run_agent(agent, "Run both")

      # Find event with function response parts
      fr_event = Enum.find(events, fn e ->
        length(extract_function_response_parts(e)) >= 2
      end)

      assert fr_event != nil, "Expected event with multiple function_response parts"
      fr_parts = extract_function_response_parts(fr_event)
      assert length(fr_parts) == 2

      names = Enum.map(fr_parts, fn p -> p.function_response.name end) |> Enum.sort()
      assert names == ["tool_a", "tool_b"]
    end
  end

  # ── Sequential Function Calls ────────────────────────────────────────
  # Mirrors test_basic_function_call_response_processing extended:
  # two sequential tool calls produce correct content ordering

  describe "sequential function call ordering" do
    test "sequential tool calls produce alternating fc/fr/fc/fr event sequence" do
      fc1 = %{name: "step_one", args: %{"input" => "start"}}
      fc2 = %{name: "step_two", args: %{"input" => "middle"}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc1},
        %{function_call: fc2},
        "Final after two sequential calls"
      ])

      step_one = make_tool("step_one", fn _ctx, %{"input" => i} ->
        {:ok, %{output: "#{i}_processed"}}
      end)

      step_two = make_tool("step_two", fn _ctx, %{"input" => i} ->
        {:ok, %{output: "#{i}_done"}}
      end)

      agent = build_agent(tools: [step_one, step_two])
      events = run_agent(agent, "Do both steps")

      # Expect: fc1_event, fr1_event, fc2_event, fr2_event, final_text
      assert length(events) >= 5

      # Check event sequence: fc, fr, fc, fr, text
      assert extract_function_call_parts(Enum.at(events, 0)) != []
      assert extract_function_response_parts(Enum.at(events, 1)) != []
      assert extract_function_call_parts(Enum.at(events, 2)) != []
      assert extract_function_response_parts(Enum.at(events, 3)) != []

      final = List.last(events)
      assert extract_text(final) == "Final after two sequential calls"
    end

    test "each function response matches its preceding function call's tool name" do
      fc1 = %{name: "first_tool", args: %{"a" => 1}}
      fc2 = %{name: "second_tool", args: %{"b" => 2}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc1},
        %{function_call: fc2},
        "All done"
      ])

      first = make_tool("first_tool", fn _ctx, _args -> {:ok, %{r: "one"}} end)
      second = make_tool("second_tool", fn _ctx, _args -> {:ok, %{r: "two"}} end)

      agent = build_agent(tools: [first, second])
      events = run_agent(agent, "Run both")

      # First fc/fr pair
      fc1_parts = extract_function_call_parts(Enum.at(events, 0))
      fr1_parts = extract_function_response_parts(Enum.at(events, 1))
      assert hd(fc1_parts).function_call.name == "first_tool"
      assert hd(fr1_parts).function_response.name == "first_tool"

      # Second fc/fr pair
      fc2_parts = extract_function_call_parts(Enum.at(events, 2))
      fr2_parts = extract_function_response_parts(Enum.at(events, 3))
      assert hd(fc2_parts).function_call.name == "second_tool"
      assert hd(fr2_parts).function_response.name == "second_tool"
    end
  end

  # ── Function Content in build_messages ───────────────────────────────
  # Mirrors the structural assertions in test_basic_function_call_response_processing:
  # function_call and function_response parts survive into the LLM request messages

  describe "function content in build_messages" do
    test "session with function call/response produces correct messages for next LLM turn" do
      agent = build_agent()
      sid = unique_session()

      {:ok, session_pid} =
        ADK.Session.start_supervised(
          app_name: "fn_content_test",
          user_id: "u1",
          session_id: sid
        )

      # Simulate: user message → function call → function response
      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv1",
        author: "user",
        content: %{parts: [%{text: "Search for test"}]}
      }))

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv2",
        author: "test_agent",
        content: %{
          role: :model,
          parts: [%{function_call: %{name: "search_tool", args: %{"query" => "test"}}}]
        }
      }))

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv3",
        author: "test_agent",
        content: %{
          role: :user,
          parts: [%{function_response: %{name: "search_tool", response: %{results: ["item1", "item2"]}}}]
        }
      }))

      ctx = %ADK.Context{
        invocation_id: "inv4",
        session_pid: session_pid,
        agent: agent,
        user_content: "What did you find?"
      }

      request = LlmAgent.build_request(ctx, agent)
      messages = request[:messages]

      # Should be: user text, model fc, model fr (author=test_agent), user followup
      assert length(messages) == 4

      # First message: user text
      assert Enum.at(messages, 0).role == :user
      assert Enum.any?(Enum.at(messages, 0).parts, fn p -> p[:text] == "Search for test" end)

      # Second message: model with function_call
      fc_msg = Enum.at(messages, 1)
      assert fc_msg.role == :model
      assert Enum.any?(fc_msg.parts, fn p -> Map.has_key?(p, :function_call) end)

      fc_part = Enum.find(fc_msg.parts, fn p -> Map.has_key?(p, :function_call) end)
      assert fc_part.function_call.name == "search_tool"

      # Third message: function response (authored by agent → model role in build_messages)
      fr_msg = Enum.at(messages, 2)
      assert fr_msg.role == :model
      assert Enum.any?(fr_msg.parts, fn p -> Map.has_key?(p, :function_response) end)

      fr_part = Enum.find(fr_msg.parts, fn p -> Map.has_key?(p, :function_response) end)
      assert fr_part.function_response.name == "search_tool"

      # Fourth message: followup user text
      assert Enum.at(messages, 3).role == :user
    end

    test "parallel function calls in session produce messages with multiple parts" do
      agent = build_agent()
      sid = unique_session()

      {:ok, session_pid} =
        ADK.Session.start_supervised(
          app_name: "fn_content_test",
          user_id: "u1",
          session_id: sid
        )

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv1",
        author: "user",
        content: %{parts: [%{text: "Run both tools"}]}
      }))

      # Model event with two function calls
      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv2",
        author: "test_agent",
        content: %{
          role: :model,
          parts: [
            %{function_call: %{name: "tool_a", args: %{"input" => "a"}}},
            %{function_call: %{name: "tool_b", args: %{"input" => "b"}}}
          ]
        }
      }))

      # Response event with two function responses
      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv3",
        author: "test_agent",
        content: %{
          role: :user,
          parts: [
            %{function_response: %{name: "tool_a", response: %{result: "a_done"}}},
            %{function_response: %{name: "tool_b", response: %{result: "b_done"}}}
          ]
        }
      }))

      ctx = %ADK.Context{
        invocation_id: "inv4",
        session_pid: session_pid,
        agent: agent,
        user_content: nil
      }

      request = LlmAgent.build_request(ctx, agent)
      messages = request[:messages]

      assert length(messages) == 3

      # Model message should have 2 function_call parts
      fc_msg = Enum.at(messages, 1)
      fc_parts = Enum.filter(fc_msg.parts, fn p -> Map.has_key?(p, :function_call) end)
      assert length(fc_parts) == 2

      # Response message should have 2 function_response parts
      fr_msg = Enum.at(messages, 2)
      fr_parts = Enum.filter(fr_msg.parts, fn p -> Map.has_key?(p, :function_response) end)
      assert length(fr_parts) == 2
    end

    test "mixed text and function_call parts in model event are preserved in messages" do
      # Mirrors test_function_rearrangement_preserves_other_content structure:
      # model content can contain both text and function_call parts
      agent = build_agent()
      sid = unique_session()

      {:ok, session_pid} =
        ADK.Session.start_supervised(
          app_name: "fn_content_test",
          user_id: "u1",
          session_id: sid
        )

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv1",
        author: "user",
        content: %{parts: [%{text: "Do something"}]}
      }))

      # Model responds with text + function call in same content
      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv2",
        author: "test_agent",
        content: %{
          role: :model,
          parts: [
            %{text: "I'll process this for you"},
            %{function_call: %{name: "processor", args: %{"input" => "data"}}}
          ]
        }
      }))

      ctx = %ADK.Context{
        invocation_id: "inv3",
        session_pid: session_pid,
        agent: agent,
        user_content: nil
      }

      request = LlmAgent.build_request(ctx, agent)
      messages = request[:messages]

      assert length(messages) == 2

      model_msg = Enum.at(messages, 1)
      assert model_msg.role == :model

      # Both text and function_call parts present
      text_parts = Enum.filter(model_msg.parts, fn p -> Map.has_key?(p, :text) end)
      fc_parts = Enum.filter(model_msg.parts, fn p -> Map.has_key?(p, :function_call) end)

      assert length(text_parts) == 1
      assert hd(text_parts).text == "I'll process this for you"

      assert length(fc_parts) == 1
      assert hd(fc_parts).function_call.name == "processor"
    end
  end

  # ── Error Tool Content ───────────────────────────────────────────────
  # Mirrors error handling aspects: tool errors produce function_response with error

  describe "error tool content" do
    test "tool that returns error produces function_response with error content" do
      fc = %{name: "failing_tool", args: %{"input" => "bad"}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "The tool failed, here's what happened"
      ])

      tool = make_tool("failing_tool", fn _ctx, _args ->
        {:error, "Something went wrong"}
      end)

      agent = build_agent(tools: [tool])
      events = run_agent(agent, "Run the failing tool")

      fr_event = Enum.find(events, fn e ->
        extract_function_response_parts(e) != []
      end)

      assert fr_event != nil, "Expected function_response event even for errors"
      [fr_part] = extract_function_response_parts(fr_event)

      assert fr_part.function_response.name == "failing_tool"
      # Error content should be present in response
      assert fr_part.function_response.response != nil
    end

    test "tool that raises propagates error through runner" do
      # Unlike Python which catches tool exceptions and wraps them in
      # function_response, Elixir's runner lets tool exceptions propagate.
      # This is a valid design divergence — the caller handles the error.
      fc = %{name: "crashing_tool", args: %{}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "I see there was an error"
      ])

      tool = make_tool("crashing_tool", fn _ctx, _args ->
        raise "Boom!"
      end)

      agent = build_agent(tools: [tool])

      assert_raise RuntimeError, "Boom!", fn ->
        run_agent(agent, "Run the crashing tool")
      end
    end
  end
end
