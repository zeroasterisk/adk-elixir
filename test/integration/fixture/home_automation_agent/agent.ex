defmodule ADK.Integration.Fixture.HomeAutomationAgent do
  @moduledoc """
  Home automation agent fixture — port of the Python ADK's
  `tests/integration/fixture/home_automation_agent/agent.py`.

  Provides 10 tools for controlling smart-home AC devices, temperatures,
  schedules, and user preferences. All state is held in-process via
  the Agent.t() so concurrent tests don't interfere.
  """

  # ── In-memory databases ──────────────────────────────────────────

  @device_db %{
    "device_1" => %{"status" => "ON", "location" => "Living Room"},
    "device_2" => %{"status" => "OFF", "location" => "Bedroom"},
    "device_3" => %{"status" => "OFF", "location" => "Kitchen"}
  }

  @temperature_db %{
    "Living Room" => 22,
    "Bedroom" => 20,
    "Kitchen" => 24
  }

  @schedule_db %{
    "device_1" => %{"time" => "18:00", "status" => "ON"},
    "device_2" => %{"time" => "22:00", "status" => "OFF"}
  }

  @user_preferences_db %{
    "user_x" => %{"preferred_temp" => 21, "location" => "Living Room"},
    "user_y" => %{"preferred_temp" => 23, "location" => "Living Room"}
  }

  # ── Tool implementations ─────────────────────────────────────────

  def get_device_info(%{"device_id" => device_id}) do
    Map.get(@device_db, device_id, "Device not found")
  end

  def set_device_info(%{"device_id" => device_id} = args) do
    status = Map.get(args, "status", "")
    location = Map.get(args, "location", "")

    if Map.has_key?(@device_db, device_id) do
      cond do
        status != "" -> "Device #{device_id} information updated: status -> #{status}."
        location != "" -> "Device #{device_id} information updated: location -> #{location}."
        true -> "No update provided."
      end
    else
      "Device not found"
    end
  end

  def get_temperature(%{"location" => location}) do
    Map.get(@temperature_db, location, "Location not found")
  end

  def set_temperature(%{"location" => location, "temperature" => temperature}) do
    if Map.has_key?(@temperature_db, location) do
      "Temperature in #{location} set to #{temperature}°C."
    else
      "Location not found"
    end
  end

  def get_user_preferences(%{"user_id" => user_id}) do
    Map.get(@user_preferences_db, user_id, "User not found")
  end

  def set_device_schedule(%{"device_id" => device_id, "time" => time, "status" => status}) do
    if Map.has_key?(@device_db, device_id) do
      "Device #{device_id} scheduled to turn #{status} at #{time}."
    else
      "Device not found"
    end
  end

  def get_device_schedule(%{"device_id" => device_id}) do
    Map.get(@schedule_db, device_id, "Schedule not found")
  end

  def celsius_to_fahrenheit(%{"celsius" => celsius}) do
    celsius * 9 / 5 + 32
  end

  def fahrenheit_to_celsius(%{"fahrenheit" => fahrenheit}) do
    trunc((fahrenheit - 32) * 5 / 9)
  end

  def list_devices(args) do
    status = Map.get(args, "status", "")
    location = Map.get(args, "location", "")

    devices =
      @device_db
      |> Enum.filter(fn {_id, info} ->
        (status == "" or info["status"] == status) and
          (location == "" or info["location"] == location)
      end)
      |> Enum.map(fn {id, info} ->
        %{"device_id" => id, "status" => info["status"], "location" => info["location"]}
      end)

    if devices == [], do: "No devices found matching the criteria.", else: devices
  end

  # ── Tool declarations ────────────────────────────────────────────

  defp tools do
    [
      ADK.Tool.FunctionTool.new(:get_device_info,
        description: "Get the current status and location of an AC device.",
        func: &get_device_info/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "device_id" => %{"type" => "string", "description" => "The unique identifier of the device."}
          },
          "required" => ["device_id"]
        }
      ),
      ADK.Tool.FunctionTool.new(:set_device_info,
        description: "Update the information of an AC device, specifically its status and/or location.",
        func: &set_device_info/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "device_id" => %{"type" => "string", "description" => "The unique identifier of the device."},
            "status" => %{"type" => "string", "description" => "The new status: 'ON' or 'OFF'."},
            "location" => %{"type" => "string", "description" => "The new location: 'Living Room', 'Bedroom', 'Kitchen'."}
          },
          "required" => ["device_id"]
        }
      ),
      ADK.Tool.FunctionTool.new(:get_temperature,
        description: "Get the current temperature in Celsius of a location.",
        func: &get_temperature/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "The location (e.g., 'Living Room', 'Bedroom', 'Kitchen')."}
          },
          "required" => ["location"]
        }
      ),
      ADK.Tool.FunctionTool.new(:set_temperature,
        description: "Set the desired temperature in Celsius for a location. Range: 18-30°C.",
        func: &set_temperature/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "The location where the temperature should be set."},
            "temperature" => %{"type" => "integer", "description" => "The desired temperature (18-30°C)."}
          },
          "required" => ["location", "temperature"]
        }
      ),
      ADK.Tool.FunctionTool.new(:get_user_preferences,
        description: "Get temperature preferences and preferred location of a user.",
        func: &get_user_preferences/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "user_id" => %{"type" => "string", "description" => "The unique identifier of the user."}
          },
          "required" => ["user_id"]
        }
      ),
      ADK.Tool.FunctionTool.new(:set_device_schedule,
        description: "Schedule a device to change its status at a specific time.",
        func: &set_device_schedule/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "device_id" => %{"type" => "string", "description" => "The unique identifier of the device."},
            "time" => %{"type" => "string", "description" => "Time in HH:MM format."},
            "status" => %{"type" => "string", "description" => "Status to set: 'ON' or 'OFF'."}
          },
          "required" => ["device_id", "time", "status"]
        }
      ),
      ADK.Tool.FunctionTool.new(:get_device_schedule,
        description: "Retrieve the schedule of a device.",
        func: &get_device_schedule/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "device_id" => %{"type" => "string", "description" => "The unique identifier of the device."}
          },
          "required" => ["device_id"]
        }
      ),
      ADK.Tool.FunctionTool.new(:celsius_to_fahrenheit,
        description: "Convert Celsius to Fahrenheit.",
        func: &celsius_to_fahrenheit/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "celsius" => %{"type" => "integer", "description" => "Temperature in Celsius."}
          },
          "required" => ["celsius"]
        }
      ),
      ADK.Tool.FunctionTool.new(:fahrenheit_to_celsius,
        description: "Convert Fahrenheit to Celsius.",
        func: &fahrenheit_to_celsius/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "fahrenheit" => %{"type" => "number", "description" => "Temperature in Fahrenheit."}
          },
          "required" => ["fahrenheit"]
        }
      ),
      ADK.Tool.FunctionTool.new(:list_devices,
        description: "Retrieve a list of AC devices, optionally filtered by status and/or location.",
        func: &list_devices/1,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "status" => %{"type" => "string", "description" => "Filter by status: 'ON' or 'OFF'."},
            "location" => %{"type" => "string", "description" => "Filter by location."}
          }
        }
      )
    ]
  end

  # ── Public API ────────────────────────────────────────────────────

  def agent do
    ADK.Agent.LlmAgent.new(
      name: "home_automation_agent",
      model: "test",
      instruction: "You are Home Automation Agent. You are responsible for controlling the devices in the home.",
      tools: tools()
    )
  end
end
