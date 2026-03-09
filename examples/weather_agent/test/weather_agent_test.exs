defmodule WeatherAgentTest do
  use ExUnit.Case

  test "agent is created with correct name" do
    agent = WeatherAgent.agent()
    assert ADK.Agent.name(agent) == "weather_bot"
  end

  test "agent has weather tool" do
    agent = WeatherAgent.agent()
    assert length(agent.tools) == 1
    [tool] = agent.tools
    assert tool.name == "get_weather"
  end

  test "runner is configured" do
    runner = WeatherAgent.runner()
    assert runner.app_name == "weather_app"
    assert ADK.Agent.name(runner.agent) == "weather_bot"
  end
end
