defmodule ADK.Agent.LlmAgentToolConfigTest do
  @moduledoc "Tests for tool_config passthrough on LlmAgent.build_request/2."
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

  describe "tool_config passthrough" do
    test "build_request includes tool_config when set on agent" do
      agent =
        LlmAgent.new(
          name: "tc_test",
          model: "mock",
          instruction: "test",
          tool_config: %{functionCallingConfig: %{mode: "ANY"}}
        )

      pid = start_session_with_events([make_event("user", "hello")])
      ctx = build_ctx(pid, agent, "current")
      req = LlmAgent.build_request(ctx, agent)

      assert req.tool_config == %{functionCallingConfig: %{mode: "ANY"}}
    end

    test "build_request omits tool_config when nil" do
      agent =
        LlmAgent.new(
          name: "tc_test2",
          model: "mock",
          instruction: "test"
        )

      pid = start_session_with_events([make_event("user", "hello")])
      ctx = build_ctx(pid, agent, "current")
      req = LlmAgent.build_request(ctx, agent)

      refute Map.has_key?(req, :tool_config)
    end
  end
end
