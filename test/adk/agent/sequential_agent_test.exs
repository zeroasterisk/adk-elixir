defmodule ADK.Agent.SequentialAgentTest do
  use ExUnit.Case, async: false
  doctest ADK.Agent.SequentialAgent

  test "runs sub-agents in sequence" do
    ADK.LLM.Mock.set_responses(["Step 1 done", "Step 2 done"])

    agent1 = ADK.Agent.LlmAgent.new(name: "step1", model: "test", instruction: "Step 1")
    agent2 = ADK.Agent.LlmAgent.new(name: "step2", model: "test", instruction: "Step 2")

    pipeline = ADK.Agent.SequentialAgent.new(name: "pipeline", sub_agents: [agent1, agent2])

    {:ok, session_pid} =
      ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "seq1")

    ctx = %ADK.Context{
      invocation_id: "inv-seq",
      session_pid: session_pid,
      agent: pipeline,
      user_content: %{text: "Go"}
    }

    events = ADK.Agent.run(pipeline, ctx)

    texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
    assert texts == ["Step 1 done", "Step 2 done"]

    GenServer.stop(session_pid)
  end
end
