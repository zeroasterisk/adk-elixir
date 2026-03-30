defmodule ADK.Plugin.MultimodalToolResultsTest do
  use ExUnit.Case, async: true
  alias ADK.Plugin.MultimodalToolResults

  setup do
    # Clear any residual process state
    Process.delete(:temp_parts_returned_by_tools)
    :ok
  end

  test "tool returning parts are added to llm request" do
    parts = [%{text: "part1"}, %{text: "part2"}]

    # Simulate after_tool hook
    result = MultimodalToolResults.after_tool(%ADK.Context{}, "mock_tool", parts)
    assert result == nil

    # State is stored in process dict
    assert Process.get(:temp_parts_returned_by_tools) == parts

    # Simulate before_model hook
    llm_request = %{messages: [%{role: :user, parts: []}]}
    {:ok, new_request} = MultimodalToolResults.before_model(%ADK.Context{}, llm_request)

    assert List.last(new_request.messages).parts == parts
    # Process dict should be cleared
    assert Process.get(:temp_parts_returned_by_tools) == nil
  end

  test "tool returning non list of parts is unchanged" do
    original_result = %{some: "data"}

    result = MultimodalToolResults.after_tool(%ADK.Context{}, "mock_tool", original_result)
    assert result == original_result
    assert Process.get(:temp_parts_returned_by_tools) == nil

    llm_request = %{messages: [%{role: :user, parts: [%{text: "original"}]}]}
    {:ok, new_request} = MultimodalToolResults.before_model(%ADK.Context{}, llm_request)

    assert List.last(new_request.messages).parts == [%{text: "original"}]
  end

  test "multiple tools returning parts are accumulated" do
    parts1 = [%{text: "part1"}]
    parts2 = [%{text: "part2"}]

    MultimodalToolResults.after_tool(%ADK.Context{}, "mock_tool_1", parts1)
    MultimodalToolResults.after_tool(%ADK.Context{}, "mock_tool_2", parts2)

    assert Process.get(:temp_parts_returned_by_tools) == parts1 ++ parts2

    llm_request = %{messages: [%{role: :user, parts: []}]}
    {:ok, new_request} = MultimodalToolResults.before_model(%ADK.Context{}, llm_request)

    assert List.last(new_request.messages).parts == parts1 ++ parts2
  end
end
