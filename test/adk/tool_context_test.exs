defmodule ADK.ToolContextTest do
  use ExUnit.Case, async: true

  alias ADK.ToolContext

  setup do
    {:ok, session_pid} =
      ADK.Session.start_link(
        app_name: "test",
        user_id: "user1",
        session_id: "tool-ctx-#{System.unique_integer([:positive])}",
        name: nil
      )

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: session_pid,
      agent: nil,
      callbacks: [],
      policies: []
    }

    tool = %{name: "test_tool"}
    tool_ctx = ToolContext.new(ctx, "call-1", tool)

    on_exit(fn -> Process.alive?(session_pid) && GenServer.stop(session_pid) end)

    %{tool_ctx: tool_ctx, session_pid: session_pid}
  end

  describe "session state read/write" do
    test "get_state returns default when key doesn't exist", %{tool_ctx: tc} do
      assert ToolContext.get_state(tc, "missing") == nil
      assert ToolContext.get_state(tc, "missing", "default") == "default"
    end

    test "put_state and get_state roundtrip", %{tool_ctx: tc} do
      assert :ok = ToolContext.put_state(tc, "key1", "value1")
      assert ToolContext.get_state(tc, "key1") == "value1"
    end

    test "put_state returns error when no session" do
      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: nil, callbacks: [], policies: []}
      tc = ToolContext.new(ctx, "call-1", %{name: "test"})
      assert {:error, :no_session} = ToolContext.put_state(tc, "key", "val")
    end
  end

  describe "artifacts (stubbed)" do
    test "get_artifact returns not_implemented", %{tool_ctx: tc} do
      assert {:error, :not_implemented} = ToolContext.get_artifact(tc, "my-artifact")
    end

    test "set_artifact returns not_implemented", %{tool_ctx: tc} do
      assert {:error, :not_implemented} = ToolContext.set_artifact(tc, "my-artifact", "data")
    end
  end

  describe "agent transfer" do
    test "transfer_to_agent returns event with transfer action", %{tool_ctx: tc} do
      event = ToolContext.transfer_to_agent(tc, "specialist_agent")
      assert event.actions.transfer_to_agent == "specialist_agent"
      assert ADK.Event.text(event) =~ "specialist_agent"
    end
  end

  describe "credentials (stubbed)" do
    test "get_credential returns not_implemented", %{tool_ctx: tc} do
      assert {:error, :not_implemented} = ToolContext.get_credential(tc, "api_key")
    end

    test "has_credential? returns false", %{tool_ctx: tc} do
      refute ToolContext.has_credential?(tc, "api_key")
    end
  end
end
