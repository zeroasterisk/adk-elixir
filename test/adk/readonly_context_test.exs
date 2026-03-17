defmodule Adk.ReadonlyContextTest do
  use ExUnit.Case, async: true

  alias Adk.ReadonlyContext

  defp create_mock_invocation_context() do
    %{
      invocation_id: "test-invocation-id",
      agent: %{name: "test-agent-name"},
      session: %{state: %{"key1" => "value1", "key2" => "value2"}},
      user_id: "test-user-id"
    }
  end

  test "invocation_id returns the invocation id" do
    mock_context = create_mock_invocation_context()
    readonly_context = ReadonlyContext.new(mock_context)
    assert readonly_context.invocation_id == "test-invocation-id"
  end

  test "agent_name returns the agent name" do
    mock_context = create_mock_invocation_context()
    readonly_context = ReadonlyContext.new(mock_context)
    assert readonly_context.agent_name == "test-agent-name"
  end

  test "state returns the session state" do
    mock_context = create_mock_invocation_context()
    readonly_context = ReadonlyContext.new(mock_context)
    state = readonly_context.state

    assert state == %{"key1" => "value1", "key2" => "value2"}
  end

  test "user_id returns the user id" do
    mock_context = create_mock_invocation_context()
    readonly_context = ReadonlyContext.new(mock_context)
    assert readonly_context.user_id == "test-user-id"
  end
end
