defmodule ADK.Agent.LlmAgentTest do
  use ExUnit.Case, async: false
  doctest ADK.Agent.LlmAgent

  setup do
    # Reset mock responses
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  test "basic LLM agent returns response" do
    ADK.LLM.Mock.set_responses(["Hello there!"])

    agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Be helpful.")

    {:ok, session_pid} =
      ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "s1")

    ctx = %ADK.Context{
      invocation_id: "inv-1",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "Hi"}
    }

    events = ADK.Agent.run(agent, ctx)
    assert length(events) == 1
    assert ADK.Event.text(hd(events)) == "Hello there!"

    GenServer.stop(session_pid)
  end

  test "agent with tools handles function calls" do
    tool =
      ADK.Tool.FunctionTool.new(:get_weather,
        description: "Get weather",
        func: fn _ctx, %{"city" => city} -> {:ok, %{temp: 22, city: city}} end,
        parameters: %{}
      )

    # First response: function call. Second response: final text.
    ADK.LLM.Mock.set_responses([
      %{
        function_call: %{name: "get_weather", args: %{"city" => "Tokyo"}, id: "fc-1"}
      },
      "The weather in Tokyo is 22°C."
    ])

    agent =
      ADK.Agent.LlmAgent.new(
        name: "weather_bot",
        model: "test",
        instruction: "Help with weather.",
        tools: [tool]
      )

    {:ok, session_pid} =
      ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "s2")

    ctx = %ADK.Context{
      invocation_id: "inv-2",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "What's the weather in Tokyo?"}
    }

    events = ADK.Agent.run(agent, ctx)

    # Should have: function_call event, function_response event, final text event
    assert length(events) >= 3

    # Last event should be the final text
    last = List.last(events)
    assert ADK.Event.text(last) == "The weather in Tokyo is 22°C."

    # Check tool was called (second event should have function_responses)
    response_event = Enum.at(events, 1)
    assert response_event.function_responses != nil
    [result] = response_event.function_responses
    assert result.name == "get_weather"
    assert result.result == %{temp: 22, city: "Tokyo"}

    GenServer.stop(session_pid)
  end

  test "agent handles LLM error" do
    # Override backend temporarily to return error
    Application.put_env(:adk, :llm_backend, ADK.LLM.ErrorMock)

    agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")

    ctx = %ADK.Context{
      invocation_id: "inv-3",
      session_pid: nil,
      agent: agent,
      user_content: %{text: "Hi"}
    }

    events = ADK.Agent.run(agent, ctx)
    assert length(events) == 1
    assert hd(events).error != nil

    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)
  end

  test "output_key saves to session state" do
    ADK.LLM.Mock.set_responses(["Research results here"])

    agent =
      ADK.Agent.LlmAgent.new(
        name: "researcher",
        model: "test",
        instruction: "Research",
        output_key: :research
      )

    {:ok, session_pid} =
      ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "s3")

    ctx = %ADK.Context{
      invocation_id: "inv-4",
      session_pid: session_pid,
      agent: agent,
      user_content: %{text: "Research Elixir"}
    }

    _events = ADK.Agent.run(agent, ctx)

    assert ADK.Session.get_state(session_pid, :research) == "Research results here"

    GenServer.stop(session_pid)
  end
end

# Helper mock that always returns errors
defmodule ADK.LLM.ErrorMock do
  @behaviour ADK.LLM

  @impl true
  def generate(_model, _request), do: {:error, :service_unavailable}
end
