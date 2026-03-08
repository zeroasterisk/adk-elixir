defmodule ADK.Tool.TransferToolTest do
  use ExUnit.Case, async: false

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  test "creates transfer tool with correct declaration" do
    sub1 = ADK.Agent.LlmAgent.new(name: "researcher", model: "test", instruction: "Research.")
    sub2 = ADK.Agent.LlmAgent.new(name: "writer", model: "test", instruction: "Write.")

    tool = ADK.Tool.TransferTool.new([sub1, sub2])

    assert tool.name == "transfer_to_agent"
    assert tool.description =~ "researcher"
    assert tool.description =~ "writer"
    assert tool.parameters.properties.agent_name.enum == ["researcher", "writer"]
  end

  test "tool_name returns canonical name" do
    assert ADK.Tool.TransferTool.tool_name() == "transfer_to_agent"
  end

  test "transfer tool executes sub-agent" do
    ADK.LLM.Mock.set_responses(["Sub-agent response"])

    sub = ADK.Agent.LlmAgent.new(name: "helper", model: "test", instruction: "Help.")
    tool = ADK.Tool.TransferTool.new([sub])

    {:ok, session_pid} =
      ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "transfer-1")

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: session_pid,
      agent: sub,
      user_content: %{text: "test"}
    }

    tool_ctx = ADK.ToolContext.new(ctx, "call-1", tool)
    result = ADK.Tool.FunctionTool.run(tool, tool_ctx, %{"agent_name" => "helper"})

    assert {:ok, %{transferred_to: "helper", result: result_text}} = result
    assert result_text =~ "Sub-agent response" || result_text == "Transfer complete."

    GenServer.stop(session_pid)
  end

  test "transfer tool returns error for unknown agent" do
    sub = ADK.Agent.LlmAgent.new(name: "helper", model: "test", instruction: "Help.")
    tool = ADK.Tool.TransferTool.new([sub])

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: nil,
      agent: sub,
      user_content: %{text: "test"}
    }

    tool_ctx = ADK.ToolContext.new(ctx, "call-1", tool)
    result = ADK.Tool.FunctionTool.run(tool, tool_ctx, %{"agent_name" => "nonexistent"})

    assert {:error, msg} = result
    assert msg =~ "Unknown agent"
  end

  test "LLM agent auto-injects transfer tool when sub_agents present" do
    # First call: LLM calls transfer_to_agent
    # Second call (sub-agent): returns result
    # Third call: parent uses result to respond
    ADK.LLM.Mock.set_responses([
      %{function_call: %{name: "transfer_to_agent", args: %{"agent_name" => "helper"}, id: "fc-1"}},
      "I am the helper sub-agent!",
      "Based on the helper's response, here is the answer."
    ])

    sub = ADK.Agent.LlmAgent.new(
      name: "helper",
      model: "test",
      instruction: "Help with questions.",
      description: "A helpful sub-agent"
    )

    agent = ADK.Agent.LlmAgent.new(
      name: "coordinator",
      model: "test",
      instruction: "Coordinate tasks.",
      sub_agents: [sub]
    )

    {:ok, session_pid} =
      ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "transfer-2")

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "Can you help me?"}
    }

    events = ADK.Agent.run(agent, ctx)

    # Should have events from the transfer flow
    assert length(events) >= 3

    # Last event should be the final response
    last = List.last(events)
    assert ADK.Event.text(last) =~ "answer"

    GenServer.stop(session_pid)
  end

  test "compiled instruction includes transfer instructions" do
    sub = ADK.Agent.LlmAgent.new(
      name: "helper",
      model: "test",
      instruction: "Help.",
      description: "Helps with things"
    )

    agent = %ADK.Agent.LlmAgent{
      name: "boss",
      model: "test",
      instruction: "Coordinate.",
      sub_agents: [sub]
    }

    ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

    instruction = ADK.InstructionCompiler.compile(agent, ctx)

    assert instruction =~ "transfer_to_agent"
    assert instruction =~ "helper: Helps with things"
  end
end
