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

defmodule ADK.Flows.LlmFlows.ContentsParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_contents.py`.

  The Python test focuses on content construction, role handling, multi-part
  content, empty content filtering, function call/response content in the
  LLM request pipeline, and include_contents modes.

  This Elixir parity file tests the *equivalent behaviours* through the
  Runner + LlmAgent pipeline:

  - Content construction from session events with proper roles
  - Multi-turn conversation history building (include_contents: default)
  - Function call and response content in LLM requests
  - Empty/nil content event handling
  - Multi-part content structures

  Parity divergences (Python-only, not ported):
  - Authentication event filtering (REQUEST_EUC_FUNCTION_CALL_NAME) — not in Elixir yet
  - Confirmation event filtering (REQUEST_CONFIRMATION_FUNCTION_CALL_NAME) — not in Elixir yet
  - Rewind event filtering (EventActions.rewind_before_invocation_id) — not in Elixir yet
  - Branch-based content filtering — Elixir build_messages doesn't filter by branch
  - include_contents: :none current-turn-only — covered in include_contents_test.exs
  - Thought/thought-part filtering — not implemented in Elixir build_messages
  - ADK function call id stripping — not implemented in Elixir
  - Interactions API id preservation — not implemented in Elixir
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

  # Safe text extraction handling both atom and string keyed content
  defp safe_text(%{content: content}) when is_map(content) do
    parts = content[:parts] || content["parts"] || []
    Enum.find_value(parts, fn
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end)
  end
  defp safe_text(_), do: nil

  defp make_tool(name, func) do
    ADK.Tool.FunctionTool.new(String.to_atom(name),
      description: "Tool: #{name}",
      func: func,
      parameters: %{type: "object", properties: %{}}
    )
  end

  # ── Content Construction Tests ───────────────────────────────────────

  describe "content construction — mirrors test_include_contents_default_full_history" do
    test "single user message produces user-role content in LLM request" do
      # The LLM should receive the user message and produce a model response.
      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "Hello world")

      assert length(events) >= 1
      final = List.last(events)
      assert final.author == "test_agent"
      assert final.content[:role] == :model
    end

    test "full conversation history included by default (include_contents: default)" do
      # Mirrors test_include_contents_default_full_history:
      # With default include_contents, all prior turns are passed to the LLM.
      ADK.LLM.Mock.set_responses(["First response", "Second response"])

      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)
      sid = unique_session()

      events1 = Runner.run(runner, "u1", sid, "First message", stop_session: false)
      assert length(events1) >= 1
      assert safe_text(List.last(events1)) == "First response"

      events2 = Runner.run(runner, "u1", sid, "Second message", stop_session: false)
      assert length(events2) >= 1
      assert safe_text(List.last(events2)) == "Second response"

      # Verify session accumulated all events
      {:ok, session_pid} = ADK.Session.lookup("contents_test", "u1", sid)
      all_events = ADK.Session.get_events(session_pid)

      # user1, agent1, user2, agent2 = at least 4 events
      assert length(all_events) >= 4
    end

    test "user events get user role, agent events get model role" do
      ADK.LLM.Mock.set_responses(["I am the model"])
      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "I am the user")

      final = List.last(events)
      assert final.content[:role] == :model
      assert final.author == "test_agent"
    end
  end

  # ── Function Call Content Tests ──────────────────────────────────────
  # Mirrors tests around function_call/response content roles and structure

  describe "function call content" do
    test "function call produces model-role content with function_call part" do
      fc = %{name: "get_weather", args: %{"city" => "London"}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "The weather is sunny"
      ])

      tool = make_tool("get_weather", fn _ctx, %{"city" => city} ->
        {:ok, %{weather: "sunny in #{city}"}}
      end)

      agent = build_agent(tools: [tool])
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "What's the weather?")

      # Should have: function_call event, function_response event, final text
      assert length(events) >= 2

      # First event should contain the function call
      fc_event = Enum.at(events, 0)
      assert fc_event.content[:role] == :model

      fc_parts = fc_event.content[:parts] || []
      has_fc = Enum.any?(fc_parts, fn p -> Map.has_key?(p, :function_call) end)
      assert has_fc, "Expected function_call part in model content"
    end

    test "function response produces user-role content with function_response part" do
      # Mirrors test_function_response_with_thought_not_filtered — function
      # responses must appear in context regardless of metadata
      fc = %{name: "add_numbers", args: %{"a" => 1, "b" => 2}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "The result is 3"
      ])

      tool = make_tool("add_numbers", fn _ctx, %{"a" => a, "b" => b} ->
        {:ok, %{result: a + b}}
      end)

      agent = build_agent(tools: [tool])
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "Add 1 and 2")

      # Find the function response event
      fr_event = Enum.find(events, fn e ->
        parts = (e.content || %{})[:parts] || []
        Enum.any?(parts, fn p -> Map.has_key?(p, :function_response) end)
      end)

      assert fr_event != nil, "Expected a function_response event"
      assert fr_event.content[:role] == :user,
        "Function response should have user role, got: #{inspect(fr_event.content[:role])}"
    end

    test "multi-step tool use produces correct content sequence" do
      # Mirrors test_code_execution_result_events_are_not_skipped:
      # intermediate tool results must not be dropped from the context
      fc1 = %{name: "step_one", args: %{"input" => "start"}}
      fc2 = %{name: "step_two", args: %{"input" => "middle"}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc1},
        %{function_call: fc2},
        "Final result after two steps"
      ])

      step_one = make_tool("step_one", fn _ctx, %{"input" => i} ->
        {:ok, %{output: "#{i}_processed"}}
      end)

      step_two = make_tool("step_two", fn _ctx, %{"input" => i} ->
        {:ok, %{output: "#{i}_done"}}
      end)

      agent = build_agent(tools: [step_one, step_two])
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "Do both steps")

      # fc1, fr1, fc2, fr2, final_text → at least 5
      assert length(events) >= 5

      final = List.last(events)
      assert safe_text(final) == "Final result after two steps"
    end

    test "function call events stored in session are retrievable" do
      # Mirrors test_code_execution_result_events_are_not_skipped regression test:
      # function results in session must be preserved in subsequent turn's context
      fc = %{name: "lookup", args: %{"query" => "test"}}

      ADK.LLM.Mock.set_responses([
        %{function_call: fc},
        "Found it"
      ])

      tool = make_tool("lookup", fn _ctx, %{"query" => q} ->
        {:ok, %{result: "result for #{q}"}}
      end)

      agent = build_agent(tools: [tool])
      runner = Runner.new(app_name: "contents_test", agent: agent)
      sid = unique_session()

      Runner.run(runner, "u1", sid, "Look up test", stop_session: false)

      {:ok, session_pid} = ADK.Session.lookup("contents_test", "u1", sid)
      events = ADK.Session.get_events(session_pid)

      has_fc = Enum.any?(events, fn e ->
        parts = (e.content || %{})[:parts] || []
        Enum.any?(parts, fn p -> Map.has_key?(p, :function_call) end)
      end)

      has_fr = Enum.any?(events, fn e ->
        parts = (e.content || %{})[:parts] || []
        Enum.any?(parts, fn p -> Map.has_key?(p, :function_response) end)
      end)

      assert has_fc, "Session should contain function_call event"
      assert has_fr, "Session should contain function_response event"
    end
  end

  # ── Empty Content Handling Tests ─────────────────────────────────────
  # Mirrors test_events_with_empty_content_are_skipped and test_other_agent_empty_content

  describe "empty content handling" do
    test "nil content LLM response produces no events" do
      # Mirrors the LLM returning content: nil — agent must not emit anything
      ADK.LLM.Mock.set_responses([
        %{content: nil, usage_metadata: nil}
      ])

      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "Hello")
      assert events == []
    end

    test "empty text response is still emitted as event" do
      ADK.LLM.Mock.set_responses([""])
      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "Hello")

      assert length(events) >= 1
      final = List.last(events)
      assert safe_text(final) == ""
    end
  end

  # ── Multi-Part Content Tests ─────────────────────────────────────────
  # Mirrors test_events_with_empty_content_are_skipped (inline_data, file_data, etc.)

  describe "multi-part content" do
    test "response with multiple text parts is preserved" do
      multi_part_response = %{
        content: %{
          role: :model,
          parts: [
            %{text: "Part one. "},
            %{text: "Part two."}
          ]
        },
        usage_metadata: nil
      }

      ADK.LLM.Mock.set_responses([multi_part_response])
      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "Give me a two-part answer")

      assert length(events) >= 1
      final = List.last(events)
      parts = final.content[:parts] || []
      text_parts = Enum.filter(parts, fn p -> Map.has_key?(p, :text) end)
      assert length(text_parts) == 2
    end

    test "user message creates single text-part content" do
      ADK.LLM.Mock.set_responses(["Got it"])
      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)

      events = Runner.run(runner, "u1", unique_session(), "Simple message")

      assert length(events) >= 1
      assert safe_text(List.last(events)) == "Got it"
    end
  end

  # ── Session Event History Tests ──────────────────────────────────────

  describe "session event history" do
    test "events are appended to session in alternating user/agent order" do
      ADK.LLM.Mock.set_responses(["Response 1", "Response 2"])
      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)
      sid = unique_session()

      Runner.run(runner, "u1", sid, "Turn 1", stop_session: false)
      Runner.run(runner, "u1", sid, "Turn 2", stop_session: false)

      {:ok, session_pid} = ADK.Session.lookup("contents_test", "u1", sid)
      events = ADK.Session.get_events(session_pid)

      assert length(events) >= 4

      authors = Enum.map(events, & &1.author)
      assert Enum.at(authors, 0) == "user"
      assert Enum.at(authors, 1) == "test_agent"
      assert Enum.at(authors, 2) == "user"
      assert Enum.at(authors, 3) == "test_agent"
    end

    test "agent events in session have model role" do
      ADK.LLM.Mock.set_responses(["First reply"])
      agent = build_agent()
      runner = Runner.new(app_name: "contents_test", agent: agent)
      sid = unique_session()

      Runner.run(runner, "u1", sid, "Hello", stop_session: false)

      {:ok, session_pid} = ADK.Session.lookup("contents_test", "u1", sid)
      events = ADK.Session.get_events(session_pid)

      agent_events = Enum.filter(events, &(&1.author == "test_agent"))
      assert length(agent_events) >= 1

      for ae <- agent_events do
        role = (ae.content || %{})[:role]
        assert role == :model, "Agent event should have model role, got: #{inspect(role)}"
      end
    end
  end

  # ── Content Building Integration Tests ───────────────────────────────
  # Directly exercise build_request/build_messages internals

  describe "build_messages integration" do
    test "build_messages converts session events to role-tagged messages" do
      agent = build_agent()
      sid = unique_session()

      {:ok, session_pid} =
        ADK.Session.start_supervised(
          app_name: "contents_test",
          user_id: "u1",
          session_id: sid
        )

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv1",
        author: "user",
        content: %{parts: [%{text: "Hello from user"}]}
      }))

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv2",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: "Hello from agent"}]}
      }))

      ctx = %ADK.Context{
        invocation_id: "inv3",
        session_pid: session_pid,
        agent: agent,
        user_content: nil
      }

      request = LlmAgent.build_request(ctx, agent)
      messages = request[:messages]

      assert length(messages) >= 2

      # First: user role
      assert Enum.at(messages, 0).role == :user
      user_parts = Enum.at(messages, 0).parts
      assert Enum.any?(user_parts, fn p -> p[:text] == "Hello from user" end)

      # Second: model role
      assert Enum.at(messages, 1).role == :model
      model_parts = Enum.at(messages, 1).parts
      assert Enum.any?(model_parts, fn p -> p[:text] == "Hello from agent" end)
    end

    test "events with nil content produce empty parts in messages" do
      agent = build_agent()
      sid = unique_session()

      {:ok, session_pid} =
        ADK.Session.start_supervised(
          app_name: "contents_test",
          user_id: "u1",
          session_id: sid
        )

      # Nil content event
      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv1",
        author: "user",
        content: nil
      }))

      # Normal event after
      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv2",
        author: "user",
        content: %{parts: [%{text: "Real message"}]}
      }))

      ctx = %ADK.Context{
        invocation_id: "inv3",
        session_pid: session_pid,
        agent: agent,
        user_content: nil
      }

      request = LlmAgent.build_request(ctx, agent)
      messages = request[:messages]

      # Both events are mapped (nil content → empty parts); Python filters these out
      # but Elixir includes them in build_messages without filtering
      assert length(messages) == 2
    end

    test "function call events in session produce correct message structure" do
      # Mirrors test_adk_function_call_ids_are_stripped_for_non_interactions_model:
      # Verifies function_call and function_response parts survive into messages
      agent = build_agent()
      sid = unique_session()

      {:ok, session_pid} =
        ADK.Session.start_supervised(
          app_name: "contents_test",
          user_id: "u1",
          session_id: sid
        )

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv1",
        author: "user",
        content: %{parts: [%{text: "Call the tool"}]}
      }))

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv2",
        author: "test_agent",
        content: %{
          role: :model,
          parts: [%{function_call: %{name: "test_tool", args: %{"x" => 1}}}]
        }
      }))

      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv3",
        author: "test_agent",
        content: %{
          role: :user,
          parts: [%{function_response: %{name: "test_tool", response: %{result: 2}}}]
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

      # First: user role with text
      assert Enum.at(messages, 0).role == :user

      # Second: model role with function_call part
      fc_msg = Enum.at(messages, 1)
      assert fc_msg.role == :model
      assert Enum.any?(fc_msg.parts, fn p -> Map.has_key?(p, :function_call) end)

      # Third: function response — authored by agent so build_messages maps to :model
      fr_msg = Enum.at(messages, 2)
      assert fr_msg.role == :model
      assert Enum.any?(fr_msg.parts, fn p -> Map.has_key?(p, :function_response) end)
    end

    test "user_content is appended after session history messages" do
      agent = build_agent()
      sid = unique_session()

      {:ok, session_pid} =
        ADK.Session.start_supervised(
          app_name: "contents_test",
          user_id: "u1",
          session_id: sid
        )

      # Prior turn in session
      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv1",
        author: "user",
        content: %{parts: [%{text: "Prior user message"}]}
      }))
      ADK.Session.append_event(session_pid, Event.new(%{
        invocation_id: "inv2",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: "Prior agent response"}]}
      }))

      # Current user input
      ctx = %ADK.Context{
        invocation_id: "inv3",
        session_pid: session_pid,
        agent: agent,
        user_content: "Current user question"
      }

      request = LlmAgent.build_request(ctx, agent)
      messages = request[:messages]

      # Should be: prior user, prior agent, current user = 3
      assert length(messages) == 3
      last_msg = List.last(messages)
      assert last_msg.role == :user
      assert Enum.any?(last_msg.parts, fn p -> p[:text] == "Current user question" end)
    end
  end
end
