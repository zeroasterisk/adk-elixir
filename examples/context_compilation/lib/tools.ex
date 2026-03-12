defmodule ContextCompilation.Tools do
  @moduledoc "Example tools for the context compilation demo."

  def get_weather do
    ADK.Tool.FunctionTool.new("get_weather",
      description: "Get the current weather for a location",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "location" => %{
            "type" => "string",
            "description" => "City name, e.g. 'Tokyo'"
          },
          "unit" => %{
            "type" => "string",
            "enum" => ["celsius", "fahrenheit"],
            "description" => "Temperature unit"
          }
        },
        "required" => ["location"]
      },
      func: fn _ctx, args ->
        location = args["location"] || "unknown"
        unit = args["unit"] || "celsius"
        {:ok, "Weather in #{location}: 22°#{if unit == "fahrenheit", do: "F", else: "C"}, partly cloudy"}
      end
    )
  end

  def get_news do
    ADK.Tool.FunctionTool.new("get_news",
      description: "Get recent news headlines",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "topic" => %{
            "type" => "string",
            "description" => "News topic to search for"
          }
        },
        "required" => ["topic"]
      },
      func: fn _ctx, args ->
        topic = args["topic"] || "general"
        {:ok, "Top headlines for #{topic}: [Demo data — no API call made]"}
      end
    )
  end
end
