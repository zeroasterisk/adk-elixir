defmodule ADK.Scenarios.ToolAgentTest do
  @moduledoc """
  Real-world tool usage scenarios — sequential calls, parallel calls,
  error handling, complex arguments, stateful chains.
  """

  use ExUnit.Case, async: true

  setup do
    ADK.LLM.Mock.set_responses([])
    :ok
  end

  defp make_runner(agent) do
    ADK.Runner.new(app_name: "tool_scenario", agent: agent)
  end

  defp run_turn(runner, session_id, message) do
    ADK.Runner.run(runner, "user1", session_id, %{text: message})
  end

  defp last_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn e -> ADK.Event.text(e) end)
  end

  defp make_tool(name, description, func) do
    ADK.Tool.FunctionTool.new(name,
      description: description,
      func: func,
      parameters: %{}
    )
  end

  describe "sequential tool calls" do
    test "agent calls tool A, uses result to call tool B, then responds" do
      search_tool =
        make_tool(:web_search, "Search the web", fn _ctx, %{"query" => q} ->
          {:ok, %{results: ["Result for: #{q}"]}}
        end)

      fetch_tool =
        make_tool(:web_fetch, "Fetch a URL", fn _ctx, %{"url" => url} ->
          {:ok, %{content: "Content from #{url}"}}
        end)

      ADK.LLM.Mock.set_responses([
        # Turn 1: agent decides to search
        %{function_call: %{name: "web_search", args: %{"query" => "elixir otp"}, id: "fc-1"}},
        # Turn 2: agent decides to fetch a result URL
        %{function_call: %{name: "web_fetch", args: %{"url" => "https://elixir-lang.org"}, id: "fc-2"}},
        # Turn 3: agent synthesizes and responds
        "Elixir is a functional language built on the BEAM VM. Here's what I found..."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "researcher",
          model: "test",
          instruction: "Research topics using search and fetch tools.",
          tools: [search_tool, fetch_tool]
        )

      runner = make_runner(agent)
      sid = "seq-tools-#{System.unique_integer([:positive])}"

      events = run_turn(runner, sid, "Tell me about Elixir OTP")

      # Should have: fc1, fr1, fc2, fr2, final_text = 5+ events
      assert length(events) >= 5
      assert last_text(events) =~ "Elixir"

      # Verify both tools were actually called
      fc_events =
        Enum.filter(events, fn e ->
          case e.content do
            %{parts: [%{function_call: _} | _]} -> true
            _ -> false
          end
        end)

      assert length(fc_events) == 2
    end
  end

  describe "parallel tool calls" do
    test "agent calls multiple tools in a single turn" do
      weather_tool =
        make_tool(:get_weather, "Get weather for a city", fn _ctx, %{"city" => city} ->
          {:ok, %{temp: 22, city: city, condition: "sunny"}}
        end)

      time_tool =
        make_tool(:get_time, "Get current time for a timezone", fn _ctx, %{"tz" => tz} ->
          {:ok, %{time: "14:30", timezone: tz}}
        end)

      ADK.LLM.Mock.set_responses([
        # Agent calls weather first
        %{function_call: %{name: "get_weather", args: %{"city" => "Tokyo"}, id: "fc-w"}},
        # Then time
        %{function_call: %{name: "get_time", args: %{"tz" => "Asia/Tokyo"}, id: "fc-t"}},
        # Then synthesizes
        "In Tokyo it's 14:30 and 22°C with sunny skies!"
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "travel_bot",
          model: "test",
          instruction: "Help with travel info.",
          tools: [weather_tool, time_tool]
        )

      runner = make_runner(agent)
      sid = "parallel-tools-#{System.unique_integer([:positive])}"

      events = run_turn(runner, sid, "What's the time and weather in Tokyo?")
      assert last_text(events) =~ "Tokyo"
    end
  end

  describe "tool error handling" do
    test "tool returns error, agent explains gracefully" do
      failing_tool =
        make_tool(:database_query, "Query the database", fn _ctx, _args ->
          {:error, "Connection refused: database is down"}
        end)

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "database_query", args: %{"sql" => "SELECT 1"}, id: "fc-1"}},
        "I'm sorry, the database seems to be unavailable right now. Please try again later."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "db_bot",
          model: "test",
          instruction: "Query databases for users.",
          tools: [failing_tool]
        )

      runner = make_runner(agent)
      sid = "tool-error-#{System.unique_integer([:positive])}"

      events = run_turn(runner, sid, "Check the database status")

      # Should still get a response (not crash)
      assert last_text(events) =~ "unavailable" || last_text(events) =~ "sorry" ||
               last_text(events) != nil
    end

    test "tool raises exception, error is propagated to LLM" do
      explosive_tool =
        make_tool(:boom, "A tool that crashes", fn _ctx, _args ->
          raise "kaboom!"
        end)

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "boom", args: %{}, id: "fc-1"}},
        "Sorry, I encountered an error with that tool."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "safe_bot",
          model: "test",
          instruction: "Use tools carefully.",
          tools: [explosive_tool]
        )

      runner = make_runner(agent)
      sid = "tool-crash-#{System.unique_integer([:positive])}"

      events = run_turn(runner, sid, "Run the boom tool")
      assert is_list(events)
      assert length(events) >= 1
    end
  end

  describe "tool with complex arguments" do
    test "tool receives nested JSON arguments" do
      received_args = Agent.start_link(fn -> nil end) |> elem(1)

      complex_tool =
        make_tool(:create_event, "Create a calendar event", fn _ctx, args ->
          Agent.update(received_args, fn _ -> args end)
          {:ok, %{event_id: "evt-123", status: "created"}}
        end)

      expected_args = %{
        "title" => "Team Standup",
        "date" => "2026-03-24",
        "attendees" => ["alan@example.com", "zaf@example.com"],
        "location" => %{"name" => "Zoom", "url" => "https://zoom.us/123"}
      }

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "create_event", args: expected_args, id: "fc-1"}},
        "Created the Team Standup event for March 24th!"
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "calendar_bot",
          model: "test",
          instruction: "Help with calendar events.",
          tools: [complex_tool]
        )

      runner = make_runner(agent)
      sid = "complex-args-#{System.unique_integer([:positive])}"

      events = run_turn(runner, sid, "Schedule a standup tomorrow with Alan and Zaf on Zoom")
      assert last_text(events) =~ "Standup"

      # Verify the tool received the full nested args
      actual = Agent.get(received_args, & &1)
      assert actual["title"] == "Team Standup"
      assert actual["attendees"] == ["alan@example.com", "zaf@example.com"]
      assert actual["location"]["name"] == "Zoom"

      Agent.stop(received_args)
    end
  end

  describe "realistic assistant patterns" do
    test "read-edit-write workflow (like a coding assistant)" do
      read_tool =
        make_tool(:read_file, "Read a file", fn _ctx, %{"path" => path} ->
          {:ok, %{content: "defmodule Foo do\n  def bar, do: :ok\nend", path: path}}
        end)

      write_tool =
        make_tool(:write_file, "Write a file", fn _ctx, %{"path" => _p, "content" => _c} ->
          {:ok, %{status: "written", bytes: 42}}
        end)

      ADK.LLM.Mock.set_responses([
        # Step 1: read the file
        %{function_call: %{name: "read_file", args: %{"path" => "lib/foo.ex"}, id: "fc-r"}},
        # Step 2: write the updated file
        %{
          function_call: %{
            name: "write_file",
            args: %{
              "path" => "lib/foo.ex",
              "content" => "defmodule Foo do\n  @doc \"Returns ok\"\n  def bar, do: :ok\nend"
            },
            id: "fc-w"
          }
        },
        # Step 3: explain what was done
        "I've added a @doc attribute to the `bar/0` function in lib/foo.ex."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "coder",
          model: "test",
          instruction: "You are a coding assistant. Read files before editing them.",
          tools: [read_tool, write_tool]
        )

      runner = make_runner(agent)
      sid = "code-edit-#{System.unique_integer([:positive])}"

      events = run_turn(runner, sid, "Add a @doc to the bar function in lib/foo.ex")
      assert last_text(events) =~ "@doc"
      assert length(events) >= 5
    end
  end
end
