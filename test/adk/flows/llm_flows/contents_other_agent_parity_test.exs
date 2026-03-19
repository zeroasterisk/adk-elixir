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

defmodule ADK.Flows.LlmFlows.ContentsOtherAgentParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_contents_other_agent.py`.

  The Python test focuses on how messages from *other* agents (not the current
  agent) are converted to user-role "For context:" messages in the LLM request
  pipeline's `request_processor`.

  This Elixir parity file tests the *equivalent behaviours* through the
  Runner + LlmAgent `build_messages` pipeline:

  - Other agent text messages appear in session and are mapped to messages
  - Other agent thoughts are included (divergence — Python filters them)
  - Other agent function calls/responses are preserved in session history
  - Empty/nil content from other agents is handled gracefully
  - Multiple agents in conversation produce correct message sequence
  - Current agent messages retain model role
  - User messages are preserved as-is

  Parity divergences (Python does, Elixir does NOT — yet):
  - Python converts other-agent messages to user-role "For context: [name] said: ..."
    Elixir maps ALL non-user events to :model role regardless of author
  - Python filters thought parts from other-agent messages
    Elixir does not filter thoughts in build_messages
  - Python formats function calls as "[name] called tool `X` with parameters: ..."
    Elixir preserves raw function_call/function_response parts
  - Python filters empty-after-thought-removal events entirely
    Elixir includes events with nil/empty content as empty-parts messages
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
        [model: "gemini-test", name: "current_agent", instruction: "You are helpful"],
        opts
      )
    )
  end

  defp start_session(app_name, sid) do
    {:ok, pid} =
      ADK.Session.start_supervised(
        app_name: app_name,
        user_id: "u1",
        session_id: sid
      )

    pid
  end

  defp make_context(agent, session_pid, opts \\ []) do
    %ADK.Context{
      invocation_id: Keyword.get(opts, :invocation_id, "inv-test"),
      session_pid: session_pid,
      agent: agent,
      user_content: Keyword.get(opts, :user_content, nil)
    }
  end

  defp get_messages(ctx, agent) do
    request = LlmAgent.build_request(ctx, agent)
    request[:messages]
  end

  # ── Other Agent Text Messages ────────────────────────────────────────
  # Mirrors test_other_agent_message_appears_as_user_context

  describe "other agent text messages in build_messages" do
    test "other agent message is included in LLM request messages" do
      # Python: other agent messages become user-role "For context:" messages
      # Elixir: other agent messages are mapped to :model role (divergence)
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "other_agent",
          content: %{role: :model, parts: [%{text: "Hello from other agent"}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) >= 1
      msg = Enum.at(messages, 0)

      # Elixir divergence: maps non-user authors to :model role
      # Python would convert to :user with "For context:" prefix
      assert msg.role == :model
      assert Enum.any?(msg.parts, fn p -> p[:text] == "Hello from other agent" end)
    end

    test "other agent message text is preserved verbatim" do
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "some_other_agent",
          content: %{role: :model, parts: [%{text: "Detailed analysis of the topic"}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 1
      text_parts = Enum.filter(Enum.at(messages, 0).parts, &Map.has_key?(&1, :text))
      assert Enum.any?(text_parts, fn p -> p[:text] == "Detailed analysis of the topic" end)
    end
  end

  # ── Thought Handling ────────────────────────────────────────────────
  # Mirrors test_other_agent_thoughts_are_excluded

  describe "other agent thought handling" do
    test "events with thought parts are included in messages (divergence from Python)" do
      # Python: filters out thought=True parts from other agents
      # Elixir: does not filter thoughts — all parts are included
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "other_agent",
          content: %{
            role: :model,
            parts: [
              %{text: "Public message", thought: false},
              %{text: "Private thought", thought: true},
              %{text: "Another public message"}
            ]
          }
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 1

      parts = Enum.at(messages, 0).parts
      # Elixir divergence: all 3 parts are included (Python would filter thought=true)
      assert length(parts) == 3
    end
  end

  # ── Function Calls From Other Agents ─────────────────────────────────
  # Mirrors test_other_agent_function_calls

  describe "other agent function calls in session" do
    test "function call from other agent is preserved in messages" do
      # Python: converts to "[agent] called tool `name` with parameters: ..."
      # Elixir: preserves raw function_call part in message
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "other_agent",
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "search_tool", args: %{"query" => "test query"}}}
            ]
          }
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 1
      msg = Enum.at(messages, 0)
      assert msg.role == :model

      # Function call part is preserved as-is
      has_fc =
        Enum.any?(msg.parts, fn p ->
          Map.has_key?(p, :function_call)
        end)

      assert has_fc, "Expected function_call part from other agent"
    end

    test "function response from other agent is preserved in messages" do
      # Mirrors test_other_agent_function_responses
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "other_agent",
          content: %{
            role: :user,
            parts: [
              %{
                function_response: %{
                  name: "search_tool",
                  response: %{"results" => ["item1", "item2"]}
                }
              }
            ]
          }
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 1

      # Elixir maps by author, not by content role — "other_agent" → :model
      msg = Enum.at(messages, 0)
      assert msg.role == :model

      has_fr =
        Enum.any?(msg.parts, fn p ->
          Map.has_key?(p, :function_response)
        end)

      assert has_fr, "Expected function_response part from other agent"
    end

    test "function call and response sequence from other agent" do
      # Mirrors test_other_agent_function_call_response
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      # Function call event
      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "other_agent",
          content: %{
            role: :model,
            parts: [
              %{text: "Let me calculate this"},
              %{function_call: %{name: "calc_tool", args: %{"query" => "6x7"}}}
            ]
          }
        })
      )

      # Function response event
      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv2",
          author: "other_agent",
          content: %{
            role: :user,
            parts: [
              %{function_response: %{name: "calc_tool", response: %{"result" => 42}}}
            ]
          }
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 2

      # First: function call event (text + function_call)
      call_msg = Enum.at(messages, 0)
      assert call_msg.role == :model
      assert Enum.any?(call_msg.parts, fn p -> p[:text] == "Let me calculate this" end)
      assert Enum.any?(call_msg.parts, fn p -> Map.has_key?(p, :function_call) end)

      # Second: function response event
      resp_msg = Enum.at(messages, 1)
      assert resp_msg.role == :model
      assert Enum.any?(resp_msg.parts, fn p -> Map.has_key?(p, :function_response) end)
    end
  end

  # ── Empty Content Handling ───────────────────────────────────────────
  # Mirrors test_other_agent_empty_content

  describe "other agent empty content" do
    test "other agent with nil content produces empty parts message" do
      # Python: filters out events that are empty after thought removal
      # Elixir: includes events with nil content as empty-parts messages
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "user",
          content: %{parts: [%{text: "Hello"}]}
        })
      )

      # Other agent with nil content
      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv2",
          author: "other_agent",
          content: nil
        })
      )

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv3",
          author: "user",
          content: %{parts: [%{text: "World"}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      # Elixir divergence: nil-content event is included (Python would filter it)
      assert length(messages) == 3

      # First and third are user messages
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 2).role == :user

      # Second is the nil-content event mapped to :model
      assert Enum.at(messages, 1).role == :model
      assert Enum.at(messages, 1).parts == []
    end

    test "other agent with empty text content is included" do
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "other_agent",
          content: %{role: :model, parts: [%{text: ""}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 1
      parts = Enum.at(messages, 0).parts
      assert Enum.any?(parts, fn p -> p[:text] == "" end)
    end
  end

  # ── Multiple Agents in Conversation ──────────────────────────────────
  # Mirrors test_multiple_agents_in_conversation

  describe "multiple agents in conversation" do
    test "messages from multiple other agents appear in correct order" do
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "user",
          content: %{parts: [%{text: "Hello everyone"}]}
        })
      )

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv2",
          author: "agent1",
          content: %{role: :model, parts: [%{text: "Hi from agent1"}]}
        })
      )

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv3",
          author: "agent2",
          content: %{role: :model, parts: [%{text: "Hi from agent2"}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 3

      # User message preserved
      assert Enum.at(messages, 0).role == :user
      assert Enum.any?(Enum.at(messages, 0).parts, fn p -> p[:text] == "Hello everyone" end)

      # Both other agent messages mapped to model role
      assert Enum.at(messages, 1).role == :model
      assert Enum.any?(Enum.at(messages, 1).parts, fn p -> p[:text] == "Hi from agent1" end)

      assert Enum.at(messages, 2).role == :model
      assert Enum.any?(Enum.at(messages, 2).parts, fn p -> p[:text] == "Hi from agent2" end)
    end

    test "interleaved user and multi-agent messages maintain order" do
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      events = [
        %{author: "user", content: %{parts: [%{text: "Turn 1"}]}},
        %{author: "agent1", content: %{role: :model, parts: [%{text: "Agent1 reply 1"}]}},
        %{author: "user", content: %{parts: [%{text: "Turn 2"}]}},
        %{author: "agent2", content: %{role: :model, parts: [%{text: "Agent2 reply"}]}},
        %{author: "user", content: %{parts: [%{text: "Turn 3"}]}}
      ]

      Enum.with_index(events, fn ev, i ->
        ADK.Session.append_event(
          session_pid,
          Event.new(Map.put(ev, :invocation_id, "inv#{i}"))
        )
      end)

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 5

      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :model, :user, :model, :user]
    end
  end

  # ── Current Agent Messages ──────────────────────────────────────────
  # Mirrors test_current_agent_messages_not_converted

  describe "current agent messages" do
    test "current agent messages retain model role" do
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      # Current agent's own message
      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "current_agent",
          content: %{role: :model, parts: [%{text: "My own message"}]}
        })
      )

      # Other agent's message
      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv2",
          author: "other_agent",
          content: %{role: :model, parts: [%{text: "Other agent message"}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 2

      # Both get :model role (Elixir doesn't differentiate current vs other agent)
      assert Enum.at(messages, 0).role == :model
      assert Enum.any?(Enum.at(messages, 0).parts, fn p -> p[:text] == "My own message" end)

      assert Enum.at(messages, 1).role == :model
      assert Enum.any?(Enum.at(messages, 1).parts, fn p -> p[:text] == "Other agent message" end)
    end
  end

  # ── User Messages Preserved ─────────────────────────────────────────
  # Mirrors test_user_messages_preserved

  describe "user messages preserved" do
    test "user messages are preserved with user role" do
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "user",
          content: %{parts: [%{text: "User message"}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 1
      assert Enum.at(messages, 0).role == :user
      assert Enum.any?(Enum.at(messages, 0).parts, fn p -> p[:text] == "User message" end)
    end

    test "user messages among other-agent messages keep user role" do
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_test", sid)

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "other_agent",
          content: %{role: :model, parts: [%{text: "Context from other"}]}
        })
      )

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv2",
          author: "user",
          content: %{parts: [%{text: "User question"}]}
        })
      )

      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv3",
          author: "other_agent",
          content: %{role: :model, parts: [%{text: "More context"}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 3
      assert Enum.at(messages, 0).role == :model
      assert Enum.at(messages, 1).role == :user
      assert Enum.at(messages, 2).role == :model
    end
  end

  # ── End-to-End: Transfer Produces Other-Agent Events ─────────────────

  describe "e2e: agent transfer produces other-agent events in session" do
    test "transfer turn produces parent-authored events with transfer signal" do
      # When a parent agent transfers to a sub-agent, the first turn produces
      # parent-authored events: the function call + the transfer signal event.
      # The sub-agent actually runs on the *next* Runner.run call (sticky transfer).
      ADK.LLM.Mock.set_responses([
        # Parent transfers
        %{function_call: %{name: "transfer_to_agent_helper", args: %{}}}
      ])

      helper =
        LlmAgent.new(
          name: "helper",
          model: "gemini-test",
          instruction: "You help people",
          description: "Helper agent"
        )

      parent =
        LlmAgent.new(
          name: "parent",
          model: "gemini-test",
          instruction: "Route to helper",
          sub_agents: [helper]
        )

      runner = Runner.new(app_name: "other_agent_e2e", agent: parent)
      sid = unique_session()

      events = Runner.run(runner, "u1", sid, "Help me", stop_session: false)

      # Transfer turn produces parent-authored events
      authors = Enum.map(events, & &1.author)
      assert Enum.all?(authors, &(&1 == "parent"))

      # Should have a transfer event with the transfer action
      transfer_event = Enum.find(events, fn e ->
        case e.actions do
          %{transfer_to_agent: name} when is_binary(name) -> true
          _ -> false
        end
      end)

      assert transfer_event != nil
      assert transfer_event.actions.transfer_to_agent == "helper"
    end

    test "session accumulates events from transfer turn for multi-agent history" do
      # After the transfer turn, session contains both user and parent events.
      # The transfer event has actions.transfer_to_agent set.
      # Note: sticky transfer (find_active_agent routing to sub-agent on next
      # turn) requires EventActions struct matching — currently a known gap
      # since llm_agent emits a plain map for actions.
      ADK.LLM.Mock.set_responses([
        # Parent transfers
        %{function_call: %{name: "transfer_to_agent_helper", args: %{}}}
      ])

      helper =
        LlmAgent.new(
          name: "helper",
          model: "gemini-test",
          instruction: "You help people",
          description: "Helper agent"
        )

      parent =
        LlmAgent.new(
          name: "parent",
          model: "gemini-test",
          instruction: "Route to helper",
          sub_agents: [helper]
        )

      runner = Runner.new(app_name: "other_agent_e2e", agent: parent)
      sid = unique_session()

      Runner.run(runner, "u1", sid, "Help me", stop_session: false)

      {:ok, session_pid} = ADK.Session.lookup("other_agent_e2e", "u1", sid)
      all_events = ADK.Session.get_events(session_pid)

      all_authors = Enum.map(all_events, & &1.author) |> Enum.uniq()
      assert "user" in all_authors
      assert "parent" in all_authors

      # Transfer event should have transfer_to_agent action
      transfer_event =
        Enum.find(all_events, fn e ->
          case e.actions do
            %{transfer_to_agent: name} when is_binary(name) -> true
            _ -> false
          end
        end)

      assert transfer_event != nil
      assert transfer_event.actions.transfer_to_agent == "helper"
    end

    test "manually seeded other-agent events in session appear in build_messages" do
      # Simulates what happens after a sub-agent has responded: its events
      # are in the session and visible to the next agent via build_messages.
      agent = build_agent()
      sid = unique_session()
      session_pid = start_session("other_agent_e2e", sid)

      # User asks
      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv1",
          author: "user",
          content: %{parts: [%{text: "What did the helper say?"}]}
        })
      )

      # Helper agent's prior response (as if transfer happened)
      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv2",
          author: "helper",
          content: %{role: :model, parts: [%{text: "I helped with the task!"}]}
        })
      )

      # Another user message
      ADK.Session.append_event(
        session_pid,
        Event.new(%{
          invocation_id: "inv3",
          author: "user",
          content: %{parts: [%{text: "Thanks, now summarize"}]}
        })
      )

      ctx = make_context(agent, session_pid)
      messages = get_messages(ctx, agent)

      assert length(messages) == 3

      # Helper's message is in the history as :model role
      helper_msg = Enum.at(messages, 1)
      assert helper_msg.role == :model
      assert Enum.any?(helper_msg.parts, fn p -> p[:text] == "I helped with the task!" end)
    end
  end
end
