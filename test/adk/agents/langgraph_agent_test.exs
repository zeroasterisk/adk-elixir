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

defmodule ADK.Agents.LangGraphAgentTest do
  @moduledoc """
  Parity tests for Python ADK's `tests/unittests/agents/test_langgraph_agent.py`.

  ## Python → Elixir Mapping

  Python's `LangGraphAgent` wraps a LangGraph `CompiledGraph` and is not
  available in Elixir (LangGraph is a Python-only library). The Elixir
  equivalent for wrapping an external graph or workflow executor is
  `ADK.Agent.Custom`, which accepts any `run_fn` — including one that calls
  an external graph, a rule engine, or any other stateful orchestrator.

  The Python tests exercise two core behaviours:

  1. **Stateless mode (no checkpointer)** — the agent builds a full message
     history from session events for every invocation, filtering to include
     only `user` events and the events produced by the last leaf agent in the
     invocation chain.

  2. **Stateful mode (with checkpointer)** — the agent's graph manages its
     own state; only the latest user turn is forwarded. This maps to the
     Elixir pattern where a `Custom` agent holds a reference to an external
     stateful process and sends only the incremental message.

  These tests verify those session-history filtering invariants using
  `ADK.Agent.Custom` with a mock "graph" (a plain function) and
  `ADK.Session` for event storage.

  ## What is not tested here

  Thread-level checkpointing (LangGraph's `checkpointer` interface) has no
  direct Elixir/ADK equivalent today. If a LangGraph-compatible Elixir
  library is added in the future, these tests should be updated to exercise
  the equivalent checkpointing behaviour directly.
  """

  use ExUnit.Case, async: true

  alias ADK.Agent.Custom
  alias ADK.Context
  alias ADK.Event

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a minimal context backed by a real session process.
  defp make_ctx(session_pid, agent, invocation_id \\ "test_invocation_id") do
    %Context{
      invocation_id: invocation_id,
      session_pid: session_pid,
      agent: agent,
      branch: agent.name
    }
  end

  # Append a user event to the session (mirrors Python's `events_list`).
  defp append_user_event(session_pid, text, invocation_id \\ "test_invocation_id") do
    event = Event.new(%{
      invocation_id: invocation_id,
      author: "user",
      content: %{role: "user", parts: [%{text: text}]}
    })
    ADK.Session.append_event(session_pid, event)
    event
  end

  # Append a model event from a named agent.
  defp append_agent_event(session_pid, author, text, invocation_id \\ "test_invocation_id") do
    event = Event.new(%{
      invocation_id: invocation_id,
      author: author,
      content: %{role: "model", parts: [%{text: text}]}
    })
    ADK.Session.append_event(session_pid, event)
    event
  end

  # Filter session events to the "stateless" message history the Python
  # `LangGraphAgent` would build when there is no checkpointer:
  #
  #   - Include all `user` events for the current invocation.
  #   - Include model events only from the last leaf agent in the invocation
  #     (i.e. exclude root-agent / orchestrator events).
  #   - Exclude intermediate orchestrator events (e.g. "root_agent").
  #
  # In Python, LangGraphAgent inspects `InvocationContext.session.events`
  # and the `branch` hierarchy to determine which events to include.
  defp build_stateless_history(events, invocation_id, orchestrator_author \\ "root_agent") do
    events
    |> Enum.filter(fn e ->
      e.invocation_id == invocation_id and
        (e.author == "user" or
           (e.author != orchestrator_author and e.content != nil and
              e.content[:role] == "model"))
    end)
    |> Enum.map(fn e ->
      role = e.content[:role] || "user"
      text = e.content[:parts] |> List.first() |> Map.get(:text, "")
      {role, text}
    end)
  end

  # Filter to "stateful" history: only the latest user message.
  defp build_stateful_history(events, invocation_id) do
    events
    |> Enum.filter(fn e ->
      e.invocation_id == invocation_id and e.author == "user"
    end)
    |> List.last()
    |> then(fn
      nil -> []
      e ->
        text = e.content[:parts] |> List.first() |> Map.get(:text, "")
        [{"user", text}]
    end)
  end

  # Build a Custom agent that records what messages it received (via the
  # captured `messages_ref`) and returns a fixed response — analogous to
  # Python's `mock_graph.invoke` mock.
  defp graph_agent(name, messages_ref, response_text, use_checkpointer) do
    Custom.new(
      name: name,
      description: "A test agent that answers weather questions",
      run_fn: fn _agent, ctx ->
        events = ADK.Session.get_events(ctx.session_pid)

        messages =
          if use_checkpointer do
            build_stateful_history(events, ctx.invocation_id)
          else
            build_stateless_history(events, ctx.invocation_id)
          end

        # Record what messages the "graph" received
        Process.put(messages_ref, messages)

        [Event.new(%{
          author: name,
          invocation_id: ctx.invocation_id,
          content: %{role: "model", parts: [%{text: response_text}]}
        })]
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Test cases
  # (Parametrised in Python; expanded to individual tests here)
  # ---------------------------------------------------------------------------

  describe "stateful graph agent (with checkpointer)" do
    # Python parametrize case 1 (checkpointer_value = MagicMock())
    # Two events in the session: user + root_agent (orchestrator).
    # Expected messages forwarded: only the system prompt + latest user turn.
    #
    # Elixir equivalent: build_stateful_history/2 returns only the latest
    # user message; orchestrator events are irrelevant.
    test "sends only the latest user message when graph manages its own state" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "s_stateful_1_#{System.unique_integer([:positive])}"
        )

      append_user_event(session_pid, "test prompt")
      append_agent_event(session_pid, "root_agent", "(some delegation)")

      msgs_key = make_ref()
      agent = graph_agent("weather_agent", msgs_key, "test response", _checkpointer = true)
      ctx = make_ctx(session_pid, agent)

      [result_event] = Custom.new(name: "weather_agent", run_fn: fn a, c -> ADK.Agent.run(a, c) end)
                       |> then(fn _ -> ADK.Agent.run(agent, ctx) end)

      assert result_event.author == "weather_agent"
      assert result_event.content[:parts] |> List.first() |> Map.get(:text) == "test response"

      # Only the latest user turn was forwarded (stateful / checkpointer mode)
      messages = Process.get(msgs_key)
      assert messages == [{"user", "test prompt"}]

      GenServer.stop(session_pid)
    end

    # Python parametrize case 3 (checkpointer_value = MagicMock(), multi-turn)
    # Four events: user1 → root → leaf → user2.
    # Expected: only user2 forwarded (checkpointer holds prior context).
    test "sends only the latest user message in a multi-turn session" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "s_stateful_3_#{System.unique_integer([:positive])}"
        )

      append_user_event(session_pid, "user prompt 1")
      append_agent_event(session_pid, "root_agent", "root agent response")
      append_agent_event(session_pid, "weather_agent", "weather agent response")
      append_user_event(session_pid, "user prompt 2")

      msgs_key = make_ref()
      agent = graph_agent("weather_agent", msgs_key, "test response", _checkpointer = true)
      ctx = make_ctx(session_pid, agent)

      [result_event] = ADK.Agent.run(agent, ctx)

      assert result_event.author == "weather_agent"

      # Stateful mode: only the latest user message
      messages = Process.get(msgs_key)
      assert messages == [{"user", "user prompt 2"}]

      GenServer.stop(session_pid)
    end
  end

  describe "stateless graph agent (no checkpointer)" do
    # Python parametrize case 2 (checkpointer_value = nil)
    # Four events: user1 → root_agent → weather_agent → user2.
    # Expected messages: system + user1 + weather_agent_response + user2.
    # (root_agent events are excluded as the orchestrator)
    test "sends full history excluding orchestrator events" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "s_stateless_2_#{System.unique_integer([:positive])}"
        )

      append_user_event(session_pid, "user prompt 1")
      append_agent_event(session_pid, "root_agent", "root agent response")
      append_agent_event(session_pid, "weather_agent", "weather agent response")
      append_user_event(session_pid, "user prompt 2")

      msgs_key = make_ref()
      agent = graph_agent("weather_agent", msgs_key, "test response", _checkpointer = false)
      ctx = make_ctx(session_pid, agent)

      [result_event] = ADK.Agent.run(agent, ctx)

      assert result_event.author == "weather_agent"

      # Stateless mode: all user + leaf-agent events; root_agent excluded
      messages = Process.get(msgs_key)
      assert messages == [
        {"user", "user prompt 1"},
        {"model", "weather agent response"},
        {"user", "user prompt 2"}
      ]

      GenServer.stop(session_pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Structural / invariant tests
  # ---------------------------------------------------------------------------

  describe "result event structure" do
    test "result event has the agent's name as author" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "s_author_#{System.unique_integer([:positive])}"
        )

      append_user_event(session_pid, "hello")

      agent = graph_agent("weather_agent", make_ref(), "the weather is sunny", false)
      [event] = ADK.Agent.run(agent, make_ctx(session_pid, agent))

      assert event.author == "weather_agent"

      GenServer.stop(session_pid)
    end

    test "result event content text matches graph response" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "s_text_#{System.unique_integer([:positive])}"
        )

      append_user_event(session_pid, "what is the weather?")

      agent = graph_agent("weather_agent", make_ref(), "partly cloudy, 22°C", false)
      [event] = ADK.Agent.run(agent, make_ctx(session_pid, agent))

      text = event.content[:parts] |> List.first() |> Map.get(:text)
      assert text == "partly cloudy, 22°C"

      GenServer.stop(session_pid)
    end

    test "agent produces exactly one result event" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "s_count_#{System.unique_integer([:positive])}"
        )

      append_user_event(session_pid, "go")

      agent = graph_agent("weather_agent", make_ref(), "done", false)
      events = ADK.Agent.run(agent, make_ctx(session_pid, agent))

      assert length(events) == 1

      GenServer.stop(session_pid)
    end
  end

  describe "session history helper unit tests" do
    # Verify the message-building helpers in isolation.

    test "build_stateless_history includes user and leaf-agent events" do
      events = [
        Event.new(%{invocation_id: "inv", author: "user",
          content: %{role: "user", parts: [%{text: "hi"}]}}),
        Event.new(%{invocation_id: "inv", author: "root_agent",
          content: %{role: "model", parts: [%{text: "orchestrating"}]}}),
        Event.new(%{invocation_id: "inv", author: "leaf_agent",
          content: %{role: "model", parts: [%{text: "leaf reply"}]}})
      ]

      history = build_stateless_history(events, "inv", "root_agent")

      assert {"user", "hi"} in history
      assert {"model", "leaf reply"} in history
      refute {"model", "orchestrating"} in history
    end

    test "build_stateless_history excludes events from other invocations" do
      events = [
        Event.new(%{invocation_id: "inv1", author: "user",
          content: %{role: "user", parts: [%{text: "old"}]}}),
        Event.new(%{invocation_id: "inv2", author: "user",
          content: %{role: "user", parts: [%{text: "new"}]}})
      ]

      history = build_stateless_history(events, "inv2")
      assert history == [{"user", "new"}]
    end

    test "build_stateful_history returns only the latest user message" do
      events = [
        Event.new(%{invocation_id: "inv", author: "user",
          content: %{role: "user", parts: [%{text: "first"}]}}),
        Event.new(%{invocation_id: "inv", author: "user",
          content: %{role: "user", parts: [%{text: "second"}]}})
      ]

      history = build_stateful_history(events, "inv")
      assert history == [{"user", "second"}]
    end

    test "build_stateful_history returns empty list when no user events" do
      events = [
        Event.new(%{invocation_id: "inv", author: "agent",
          content: %{role: "model", parts: [%{text: "reply"}]}})
      ]

      assert build_stateful_history(events, "inv") == []
    end
  end
end
