defmodule ADK.StreamingParityTest do
  @moduledoc """
  Parity tests for Python ADK's `tests/unittests/streaming/test_streaming.py`.

  This suite ensures Elixir's streaming runner behavior mirrors Python's,
  handling basic text streaming, single/multiple/parallel function calls,
  and sync tools correctly via `ADK.Runner.run_streaming/5`.
  Live audio streaming from Python is omitted, as it's not on Elixir's roadmap.
  """

  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Runner
  alias ADK.Tool.FunctionTool
  alias ADK.Event

  setup do
    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)

    on_exit(fn ->
      Application.delete_env(:adk, :llm_backend)
    end)

    :ok
  end

  describe "Streaming parity" do
    test "test_streaming (basic turn complete)" do
      ADK.LLM.Mock.set_responses(["turn complete"])

      agent = LlmAgent.new(name: "root_agent", model: "dummy", tools: [])
      runner = %Runner{app_name: "test", agent: agent}

      pid = self()

      res_events =
        Runner.run_streaming(runner, "user-1", "sess-1", "Hello",
          on_event: fn event -> send(pid, {:streamed, event}) end
        )

      assert length(res_events) > 0
      assert_receive {:streamed, event}, 500
      assert event.author == "root_agent"
    end

    test "test_live_streaming_function_call_single" do
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{
            name: "get_weather",
            args: %{"location" => "San Francisco", "unit" => "celsius"}
          }
        },
        "turn complete"
      ])

      tool =
        FunctionTool.new("get_weather",
          description: "Get weather",
          func: fn _ctx, %{"location" => loc, "unit" => unit} ->
            %{"temperature" => 22, "condition" => "sunny", "location" => loc, "unit" => unit}
          end
        )

      agent = LlmAgent.new(name: "root_agent", model: "dummy", tools: [tool])
      runner = %Runner{app_name: "test", agent: agent}

      pid = self()

      res_events =
        Runner.run_streaming(runner, "user-1", "sess-2", "What is the weather in San Francisco?",
          on_event: fn event -> send(pid, {:streamed, event}) end
        )

      assert length(res_events) >= 1

      function_call_found =
        Enum.any?(res_events, fn event ->
          Event.has_function_calls?(event) and
            hd(Event.function_calls(event)).name == "get_weather"
        end)

      assert function_call_found

      fc_part =
        Enum.find_value(res_events, fn e ->
          calls = Event.function_calls(e)
          if calls != [], do: hd(calls), else: nil
        end)

      assert fc_part.args["location"] == "San Francisco"
      assert fc_part.args["unit"] == "celsius"

      function_response_found =
        Enum.any?(res_events, fn event ->
          Event.has_function_responses?(event) and
            hd(Event.function_responses(event)).name == "get_weather"
        end)

      assert function_response_found

      fr_part =
        Enum.find_value(res_events, fn e ->
          responses = Event.function_responses(e)
          if responses != [], do: hd(responses), else: nil
        end)

      assert fr_part.response["temperature"] == 22
      assert fr_part.response["condition"] == "sunny"
    end

    test "test_live_streaming_function_call_multiple" do
      # Mock returning two function calls in succession
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "get_weather", args: %{"location" => "San Francisco"}}},
        %{function_call: %{name: "get_time", args: %{"timezone" => "PST"}}},
        "turn complete"
      ])

      weather_tool =
        FunctionTool.new("get_weather",
          description: "Get weather",
          func: fn _ctx, %{"location" => loc} ->
            %{"temperature" => 22, "condition" => "sunny", "location" => loc}
          end
        )

      time_tool =
        FunctionTool.new("get_time",
          description: "Get time",
          func: fn _ctx, %{"timezone" => tz} ->
            %{"time" => "14:30", "timezone" => tz}
          end
        )

      agent = LlmAgent.new(name: "root_agent", model: "dummy", tools: [weather_tool, time_tool])
      runner = %Runner{app_name: "test", agent: agent}

      pid = self()

      res_events =
        Runner.run_streaming(runner, "user-1", "sess-3", "What is the weather and current time?",
          on_event: fn event -> send(pid, {:streamed, event}) end
        )

      assert length(res_events) >= 1

      weather_call_found =
        Enum.any?(res_events, fn event ->
          Event.has_function_calls?(event) and
            hd(Event.function_calls(event)).name == "get_weather"
        end)

      time_call_found =
        Enum.any?(res_events, fn event ->
          Event.has_function_calls?(event) and hd(Event.function_calls(event)).name == "get_time"
        end)

      assert weather_call_found
      assert time_call_found
    end

    test "test_live_streaming_function_call_parallel" do
      # Mock returning two parallel function calls in the same response
      ADK.LLM.Mock.set_responses([
        %{
          content: %{
            role: :model,
            parts: [
              %{function_call: %{name: "get_weather", args: %{"location" => "San Francisco"}}},
              %{function_call: %{name: "get_weather", args: %{"location" => "New York"}}}
            ]
          }
        },
        "turn complete"
      ])

      weather_tool =
        FunctionTool.new("get_weather",
          description: "Get weather",
          func: fn _ctx, %{"location" => loc} ->
            temps = %{"San Francisco" => 22, "New York" => 15}
            %{"temperature" => Map.get(temps, loc, 20), "location" => loc}
          end
        )

      agent = LlmAgent.new(name: "root_agent", model: "dummy", tools: [weather_tool])
      runner = %Runner{app_name: "test", agent: agent}

      pid = self()

      res_events =
        Runner.run_streaming(runner, "user-1", "sess-4", "Compare weather in SF and NYC",
          on_event: fn event -> send(pid, {:streamed, event}) end
        )

      assert length(res_events) >= 1

      sf_call_found =
        Enum.any?(res_events, fn event ->
          Enum.any?(Event.function_calls(event), fn fc ->
            fc.name == "get_weather" and fc.args["location"] == "San Francisco"
          end)
        end)

      nyc_call_found =
        Enum.any?(res_events, fn event ->
          Enum.any?(Event.function_calls(event), fn fc ->
            fc.name == "get_weather" and fc.args["location"] == "New York"
          end)
        end)

      assert sf_call_found and nyc_call_found
    end

    test "test_live_streaming_function_call_with_error" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "get_weather", args: %{"location" => "Invalid Location"}}},
        "turn complete"
      ])

      weather_tool =
        FunctionTool.new("get_weather",
          description: "Get weather",
          func: fn _ctx, %{"location" => loc} ->
            if loc == "Invalid Location" do
              %{"error" => "Location not found"}
            else
              %{"temperature" => 22, "condition" => "sunny", "location" => loc}
            end
          end
        )

      agent = LlmAgent.new(name: "root_agent", model: "dummy", tools: [weather_tool])
      runner = %Runner{app_name: "test", agent: agent}

      pid = self()

      res_events =
        Runner.run_streaming(runner, "user-1", "sess-5", "What is weather in Invalid Location?",
          on_event: fn event -> send(pid, {:streamed, event}) end
        )

      assert length(res_events) >= 1

      function_call_found =
        Enum.any?(res_events, fn event ->
          Event.has_function_calls?(event) and
            hd(Event.function_calls(event)).name == "get_weather"
        end)

      assert function_call_found

      fr_part =
        Enum.find_value(res_events, fn e ->
          parts = Event.function_responses(e)
          if parts != [], do: hd(parts), else: nil
        end)

      assert fr_part.response["error"] == "Location not found"
    end

    test "test_live_streaming_function_call_sync_tool" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "calculate", args: %{"x" => 5, "y" => 3}}},
        "turn complete"
      ])

      calc_tool =
        FunctionTool.new("calculate",
          description: "Calculate",
          func: fn _ctx, %{"x" => x, "y" => y} ->
            %{"result" => x + y, "operation" => "addition"}
          end
        )

      agent = LlmAgent.new(name: "root_agent", model: "dummy", tools: [calc_tool])
      runner = %Runner{app_name: "test", agent: agent}

      pid = self()

      res_events =
        Runner.run_streaming(runner, "user-1", "sess-6", "Calculate 5 plus 3",
          on_event: fn event -> send(pid, {:streamed, event}) end
        )

      assert length(res_events) >= 1

      function_call_found =
        Enum.any?(res_events, fn event ->
          Event.has_function_calls?(event) and hd(Event.function_calls(event)).name == "calculate"
        end)

      assert function_call_found

      fr_part =
        Enum.find_value(res_events, fn e ->
          parts = Event.function_responses(e)
          if parts != [], do: hd(parts), else: nil
        end)

      assert fr_part.response["result"] == 8
    end

    test "test_live_streaming_text_content_persisted_in_session" do
      ADK.LLM.Mock.set_responses(["Hello! How can I help you?"])

      agent = LlmAgent.new(name: "root_agent", model: "dummy", tools: [])
      # Use an actual session store to verify persistence
      runner = %Runner{
        app_name: "test",
        agent: agent,
        session_store: {ADK.Session.Store.InMemory, []}
      }

      {:ok, session_pid} =
        ADK.Session.start_supervised(
          app_name: "test",
          user_id: "user-1",
          session_id: "sess-7",
          store: {ADK.Session.Store.InMemory, []}
        )

      user_text = "Hello, this is a test message"
      Runner.run_streaming(runner, "user-1", "sess-7", user_text, stop_session: false)

      events = ADK.Session.get_events(session_pid)

      user_content_found =
        Enum.any?(events, fn e ->
          e.author == "user" and ADK.Event.text(e) == user_text
        end)

      assert user_content_found
    end
  end
end
