defmodule ADK.Agent.LlmAgentOrphanedResponsesTest do
  @moduledoc """
  Tests that `truncate_history` drops leading orphaned function_response
  messages that lost their matching function_call due to truncation.
  """
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Event

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

  defp make_event(author, parts) when is_list(parts) do
    role = if author == "user", do: :user, else: :model
    Event.new(%{invocation_id: "inv-1", author: author, content: %{role: role, parts: parts}})
  end

  defp make_event(author, text) when is_binary(text) do
    make_event(author, [%{text: text}])
  end

  defp build_ctx(session_pid, agent) do
    %ADK.Context{
      session_pid: session_pid,
      agent: agent,
      invocation_id: "inv-1",
      user_content: %{text: "current"},
      plugins: [],
      callbacks: [],
      run_config: nil
    }
  end

  defp extract_parts(request) do
    Enum.map(request.messages, fn msg -> msg.parts end)
  end

  describe "drop_leading_orphaned_responses on truncation" do
    test "orphaned function_response at truncation boundary is dropped" do
      # Build history: user, model(func_call), model(func_response), user, model
      # With max_history_turns=1, we keep last 2 messages: [user, model]
      # But if truncation lands so func_response is first, it gets dropped.
      #
      # 5 messages, max_history_turns=1 → keep last 2 → [u2, m2] — no orphan.
      # We need truncation to land ON a function_response.
      # 4 messages with max_history_turns=1 → keep last 2 → [func_resp, u2]
      # The func_resp is orphaned → should be dropped → [u2]

      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 1)

      events = [
        make_event("user", "u1"),
        make_event("model", [%{function_call: %{name: "tool1", args: %{}}}]),
        make_event("model", [%{function_response: %{name: "tool1", response: %{output: "ok"}}}]),
        make_event("user", "u2")
      ]

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent)
      req = LlmAgent.build_request(ctx, agent)
      parts = extract_parts(req)

      # The func_response should be dropped as orphaned.
      # Remaining from history: just [u2], plus current user msg.
      has_func_response =
        Enum.any?(List.flatten(parts), fn
          %{function_response: _} -> true
          _ -> false
        end)

      refute has_func_response, "orphaned function_response should be dropped"

      texts =
        parts
        |> List.flatten()
        |> Enum.map(& &1[:text])
        |> Enum.reject(&is_nil/1)

      assert "u2" in texts
      assert "current" in texts
    end

    test "multiple consecutive orphaned function_responses are all dropped" do
      events = [
        make_event("user", "u1"),
        make_event("model", [%{function_call: %{name: "t1", args: %{}}}]),
        make_event("model", [%{function_response: %{name: "t1", response: %{output: "r1"}}}]),
        make_event("model", [%{function_response: %{name: "t2", response: %{output: "r2"}}}]),
        make_event("user", "u2"),
        make_event("model", "m2")
      ]

      # 6 messages, max_history_turns=1 → keep last 2 → [u2, m2] — no orphan
      # max_history_turns=2 → keep last 4 → [func_resp1, func_resp2, u2, m2]
      agent2 = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 2)

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent2)
      req = LlmAgent.build_request(ctx, agent2)
      parts = extract_parts(req)

      has_func_response =
        Enum.any?(List.flatten(parts), fn
          %{function_response: _} -> true
          _ -> false
        end)

      refute has_func_response, "all orphaned function_responses should be dropped"

      texts =
        parts
        |> List.flatten()
        |> Enum.map(& &1[:text])
        |> Enum.reject(&is_nil/1)

      assert "u2" in texts
      assert "m2" in texts
    end

    test "string-keyed function_response is also detected as orphaned" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 1)

      events = [
        make_event("user", "u1"),
        make_event("model", [%{function_call: %{name: "tool1", args: %{}}}]),
        make_event("model", [%{"function_response" => %{"name" => "tool1", "response" => %{"output" => "ok"}}}]),
        make_event("user", "u2")
      ]

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent)
      req = LlmAgent.build_request(ctx, agent)
      parts = extract_parts(req)

      has_func_response =
        Enum.any?(List.flatten(parts), fn
          %{"function_response" => _} -> true
          %{function_response: _} -> true
          _ -> false
        end)

      refute has_func_response, "string-keyed orphaned function_response should be dropped"
    end

    test "non-orphaned function_response (with preceding call) is preserved" do
      # History where function_call and function_response are both in the kept window
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 2)

      events = [
        make_event("user", "u1"),
        make_event("model", "m1"),
        make_event("model", [%{function_call: %{name: "tool1", args: %{}}}]),
        make_event("model", [%{function_response: %{name: "tool1", response: %{output: "ok"}}}])
      ]

      # 4 messages, max_history_turns=2 → keep all 4 → no truncation → no orphan
      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent)
      req = LlmAgent.build_request(ctx, agent)
      parts = extract_parts(req)

      has_func_response =
        Enum.any?(List.flatten(parts), fn
          %{function_response: _} -> true
          _ -> false
        end)

      assert has_func_response, "non-orphaned function_response should be preserved"
    end

    test "no truncation needed — all messages preserved including func pairs" do
      agent = LlmAgent.new(name: "a", model: "m", instruction: "hi", max_history_turns: 10)

      events = [
        make_event("user", "u1"),
        make_event("model", [%{function_call: %{name: "tool1", args: %{}}}]),
        make_event("model", [%{function_response: %{name: "tool1", response: %{output: "ok"}}}]),
        make_event("user", "u2")
      ]

      pid = start_session_with_events(events)
      ctx = build_ctx(pid, agent)
      req = LlmAgent.build_request(ctx, agent)

      # All 4 history + 1 current = 5
      assert length(req.messages) == 5
    end
  end
end
