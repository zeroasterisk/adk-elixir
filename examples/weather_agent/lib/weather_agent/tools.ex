defmodule WeatherAgent.Tools do
  @moduledoc """
  Weather tools for the weather agent.
  """

  @doc """
  Returns the get_weather function tool definition.
  """
  def get_weather_tool do
    ADK.Tool.FunctionTool.new("get_weather",
      description: "Get the current weather for a city. Returns temperature, conditions, and humidity.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "city" => %{
            "type" => "string",
            "description" => "The city name, e.g. 'Tokyo', 'New York', 'London'"
          }
        },
        "required" => ["city"]
      },
      func: fn _ctx, args -> {:ok, get_weather(args)} end
    )
  end

  @doc """
  Simulated weather lookup.

  In a real application, this would call a weather API like OpenWeatherMap.

  ## Examples

      iex> result = WeatherAgent.Tools.get_weather(%{"city" => "Tokyo"})
      iex> is_map(result)
      true
      iex> Map.has_key?(result, "temperature_celsius")
      true
  """
  def get_weather(%{"city" => city}) do
    # Simulated weather data - in production, call a real API
    weather_data = %{
      "Tokyo" => %{"temperature_celsius" => 22, "conditions" => "Partly Cloudy", "humidity" => 65},
      "New York" => %{"temperature_celsius" => 18, "conditions" => "Sunny", "humidity" => 45},
      "London" => %{"temperature_celsius" => 14, "conditions" => "Rainy", "humidity" => 80},
      "Paris" => %{"temperature_celsius" => 16, "conditions" => "Overcast", "humidity" => 70},
      "Sydney" => %{"temperature_celsius" => 26, "conditions" => "Clear", "humidity" => 55}
    }

    case Map.get(weather_data, city) do
      nil ->
        # Generate plausible data for unknown cities
        %{
          "city" => city,
          "temperature_celsius" => Enum.random(5..35),
          "conditions" => Enum.random(["Sunny", "Cloudy", "Rainy", "Clear", "Windy"]),
          "humidity" => Enum.random(30..90),
          "note" => "Simulated data"
        }

      data ->
        Map.put(data, "city", city)
    end
  end

  def get_weather(_args) do
    %{"error" => "Missing required parameter: city"}
  end
end
