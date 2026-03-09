defmodule WeatherAgent.ToolsTest do
  use ExUnit.Case

  alias WeatherAgent.Tools

  test "get_weather returns data for known city" do
    result = Tools.get_weather(%{"city" => "Tokyo"})
    assert result["city"] == "Tokyo"
    assert result["temperature_celsius"] == 22
    assert result["conditions"] == "Partly Cloudy"
    assert result["humidity"] == 65
  end

  test "get_weather returns data for all known cities" do
    for city <- ["Tokyo", "New York", "London", "Paris", "Sydney"] do
      result = Tools.get_weather(%{"city" => city})
      assert result["city"] == city
      assert is_integer(result["temperature_celsius"])
      assert is_binary(result["conditions"])
      assert is_integer(result["humidity"])
    end
  end

  test "get_weather returns simulated data for unknown city" do
    result = Tools.get_weather(%{"city" => "Atlantis"})
    assert result["city"] == "Atlantis"
    assert is_integer(result["temperature_celsius"])
    assert is_binary(result["conditions"])
    assert result["note"] == "Simulated data"
  end

  test "get_weather handles missing city parameter" do
    result = Tools.get_weather(%{})
    assert result["error"] =~ "Missing"
  end

  test "get_weather_tool returns a FunctionTool" do
    tool = Tools.get_weather_tool()
    assert tool.name == "get_weather"
    assert is_binary(tool.description)
    assert is_map(tool.parameters)
    assert is_function(tool.func, 2)
  end
end
