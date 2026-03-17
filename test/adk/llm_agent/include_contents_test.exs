defmodule ADK.LlmAgent.IncludeContentsTest do
  use ExUnit.Case

  alias ADK.Agents.LlmAgent
  alias ADK.Agents.SequentialAgent
  alias ADK.Testing.Runner
  alias ADK.Testing.MockModel
  alias ADK.Testing.SimplifiedContent

  defp simple_tool(message) do
    %{result: "Tool processed: #{message}"}
  end

  test "include_contents: :default preserves conversation history" do
    model =
      MockModel.new(%{
        responses: [
          {:function_call, "simple_tool", %{message: "first"}},
          "First response",
          {:function_call, "simple_tool", %{message: "second"}},
          "Second response"
        ]
      })

    agent =
      LlmAgent.new(%{
        name: "test_agent",
        model: model,
        include_contents: :default,
        instruction: "You are a helpful assistant",
        tools: [&simple_tool/1]
      })

    runner = Runner.new(agent)
    Runner.run(runner, "First message")
    Runner.run(runner, "Second message")

    requests = MockModel.get_requests(model)

    # First turn requests
    assert [
             SimplifiedContent.user("First message")
           ] == MockModel.simplify_contents(requests |> Enum.at(0) |> Map.get(:contents))

    assert [
             SimplifiedContent.user("First message"),
             SimplifiedContent.model({:function_call, "simple_tool", %{message: "first"}}),
             SimplifiedContent.user({:function_response, "simple_tool",
                                     %{result: "Tool processed: first"}})
           ] == MockModel.simplify_contents(requests |> Enum.at(1) |> Map.get(:contents))

    # Second turn should include full conversation history
    assert [
             SimplifiedContent.user("First message"),
             SimplifiedContent.model({:function_call, "simple_tool", %{message: "first"}}),
             SimplifiedContent.user({:function_response, "simple_tool",
                                     %{result: "Tool processed: first"}}),
             SimplifiedContent.model("First response"),
             SimplifiedContent.user("Second message")
           ] == MockModel.simplify_contents(requests |> Enum.at(2) |> Map.get(:contents))

    # Second turn with tool should include full history + current tool interaction
    assert [
             SimplifiedContent.user("First message"),
             SimplifiedContent.model({:function_call, "simple_tool", %{message: "first"}}),
             SimplifiedContent.user({:function_response, "simple_tool",
                                     %{result: "Tool processed: first"}}),
             SimplifiedContent.model("First response"),
             SimplifiedContent.user("Second message"),
             SimplifiedContent.model({:function_call, "simple_tool", %{message: "second"}}),
             SimplifiedContent.user({:function_response, "simple_tool",
                                     %{result: "Tool processed: second"}})
           ] == MockModel.simplify_contents(requests |> Enum.at(3) |> Map.get(:contents))
  end

  test "include_contents: :none excludes conversation history" do
    model =
      MockModel.new(%{
        responses: [
          {:function_call, "simple_tool", %{message: "first"}},
          "First response",
          "Second response"
        ]
      })

    agent =
      LlmAgent.new(%{
        name: "test_agent",
        model: model,
        include_contents: :none,
        instruction: "You are a helpful assistant",
        tools: [&simple_tool/1]
      })

    runner = Runner.new(agent)
    Runner.run(runner, "First message")
    Runner.run(runner, "Second message")

    requests = MockModel.get_requests(model)

    # First turn behavior
    assert [
             SimplifiedContent.user("First message")
           ] == MockModel.simplify_contents(requests |> Enum.at(0) |> Map.get(:contents))

    assert [
             SimplifiedContent.user("First message"),
             SimplifiedContent.model({:function_call, "simple_tool", %{message: "first"}}),
             SimplifiedContent.user({:function_response, "simple_tool",
                                     %{result: "Tool processed: first"}})
           ] == MockModel.simplify_contents(requests |> Enum.at(1) |> Map.get(:contents))

    # Second turn should only have current input, no history
    assert [
             SimplifiedContent.user("Second message")
           ] == MockModel.simplify_contents(requests |> Enum.at(2) |> Map.get(:contents))

    # System instruction and tools should be preserved
    assert "You are a helpful assistant" ==
             (requests |> Enum.at(0) |> Map.get(:config) |> Map.get(:system_instruction))

    assert length(requests |> Enum.at(0) |> Map.get(:config) |> Map.get(:tools)) > 0
  end

  test "include_contents: :none with sequential agents" do
    agent1_model = MockModel.new(%{responses: ["Agent1 response: XYZ"]})

    agent1 =
      LlmAgent.new(%{
        name: "agent1",
        model: agent1_model,
        instruction: "You are Agent1"
      })

    agent2_model = MockModel.new(%{responses: ["Agent2 final response"]})

    agent2 =
      LlmAgent.new(%{
        name: "agent2",
        model: agent2_model,
        include_contents: :none,
        instruction: "You are Agent2"
      })

    sequential_agent =
      SequentialAgent.new(%{
        name: "sequential_test_agent",
        sub_agents: [agent1, agent2]
      })

    runner = Runner.new(sequential_agent)
    events = Runner.run(runner, "Original user request")

    simplified_events = Enum.filter(events, &(&1.content != nil))
    assert 2 == length(simplified_events)
    assert "agent1" == (simplified_events |> Enum.at(0) |> Map.get(:author))
    assert "agent2" == (simplified_events |> Enum.at(1) |> Map.get(:author))

    # Agent1 sees original user request
    agent1_contents =
      agent1_model |> MockModel.get_requests() |> Enum.at(0) |> Map.get(:contents) |> MockModel.simplify_contents()

    assert Enum.any?(agent1_contents, fn
             {:user, "Original user request"} -> true
             _ -> false
           end)

    # Agent2 with include_contents: :none should not see original request
    agent2_contents =
      agent2_model |> MockModel.get_requests() |> Enum.at(0) |> Map.get(:contents) |> MockModel.simplify_contents()

    refute Enum.any?(agent2_contents, fn
             {:user, "Original user request"} -> true
             _ -> false
           end)

    assert Enum.any?(agent2_contents, fn
            {:user, content_string} -> String.contains?(content_string, "Agent1 response")
             _ -> false
           end)
  end
end
