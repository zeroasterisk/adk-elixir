defmodule ADK.Agent.LlmAgentMaxHistoryTest do
  @moduledoc "Tests for the :max_history_turns option on LlmAgent."
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Event

  # Helper: start a session and seed it with events
  defp start_session_with_events(events) do
    {:ok, pid} =
      ADK.Session.start_link(
        app_name: "test",
        user_id: "u1",
        session_id: "s-#{System.unique_integer([:positive])}",
        name: nil
      )

    for e <- events, do: ADK.Session.append_event(pid, e)
    pid
  end

  defp make_event(author, text) do
    Event.new(%{
      invocation_id: "inv-1",
      author: author,
      content: %{role: if(author == "user", do: :user, else: :model), parts: [%{text: text}]}
    })
  end

  defp build_ctx(session_pid, agent, user_text) do
    %ADK.Context{
      session_pid: session_pid,
      agent: agent,
      invocation_id: "inv-1",
      user_content: if(user_text, do: %{text: user_text}),
      plugins: [],
      callbacks: [],
      run_config: nil
    }
  end

  defp extract_texts(request) do
    Enum.map(request.messages, fn msg ->
      Enum.map_join(msg.parts, fn p -> p[:text] || "" end)
    end)
  end

  # ------------------------------------------------------------------
  # Struct defaults
  # ------------------------------------------------------------------

  describe "struct defaults" do
    test "max_history_turns defaults to nil" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "i")
      assert agent.max_history_turns == nil
    end

    test "max_history_turns can be set via new/1" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "i", max_history_turns: 3)
      assert agent.max_history_turns == 3
    end
  end

  # ------------------------------------------------------------------
  # Truncation via build_request
  # ------------------------------------------------------------------

  describe "build_request truncation" do
    test "nil max_history_turns keeps all history" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi")

      events = [
        make_event("user", "u1"),
        make_event("model", "m1"),
        make_event("user", "u2"),
        make_event("model", "m2"),
        make_event("user", "u3"),
        make_event("model", "m3")
      ]

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent, "current")
      req = LlmAgent.build_request(ctx, agent)
      texts = extract_texts(req)

      # 6 history + 1 current user message = 7
      assert length(texts) == 7
      assert "u1" in texts
      assert "current" in texts
    end

    test "max_history_turns=1 keeps last 2 history messages" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 1)

      events = [
        make_event("user", "u1"),
        make_event("model", "m1"),
        make_event("user", "u2"),
        make_event("model", "m2")
      ]

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent, "current")
      req = LlmAgent.build_request(ctx, agent)
      texts = extract_texts(req)

      # last 2 history msgs (u2, m2) + current user msg
      assert length(texts) == 3
      refute "u1" in texts
      refute "m1" in texts
      assert "u2" in texts
      assert "m2" in texts
      assert "current" in texts
    end

    test "max_history_turns=2 keeps last 4 history messages" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 2)

      events = [
        make_event("user", "u1"),
        make_event("model", "m1"),
        make_event("user", "u2"),
        make_event("model", "m2"),
        make_event("user", "u3"),
        make_event("model", "m3")
      ]

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent, "current")
      req = LlmAgent.build_request(ctx, agent)
      texts = extract_texts(req)

      # last 4 history msgs + current = 5
      assert length(texts) == 5
      refute "u1" in texts
      refute "m1" in texts
      assert "u2" in texts
      assert "m2" in texts
      assert "u3" in texts
      assert "m3" in texts
      assert "current" in texts
    end

    test "no truncation when history is shorter than limit" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 10)

      events = [
        make_event("user", "u1"),
        make_event("model", "m1")
      ]

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent, "current")
      req = LlmAgent.build_request(ctx, agent)
      texts = extract_texts(req)

      assert length(texts) == 3
      assert "u1" in texts
    end

    test "odd-length history still truncates to last N*2" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 1)

      # 3 events (odd)
      events = [
        make_event("user", "u1"),
        make_event("model", "m1"),
        make_event("user", "u2")
      ]

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent, "current")
      req = LlmAgent.build_request(ctx, agent)
      texts = extract_texts(req)

      # last 2 of 3 history msgs: m1, u2; + current = 3
      assert length(texts) == 3
      refute "u1" in texts
      assert "m1" in texts
      assert "u2" in texts
    end

    test "empty history with max_history_turns set" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 2)

      pid = start_session_with_events([])
      ctx = build_ctx(pid, agent, "hello")
      req = LlmAgent.build_request(ctx, agent)
      texts = extract_texts(req)

      assert texts == ["hello"]
    end
  end
end
