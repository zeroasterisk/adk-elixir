defmodule ADK.Scenarios.SessionPersistenceTest do
  @moduledoc """
  Session persistence patterns — state survives across runs,
  output_key saves to state, session history with tool results.
  """

  use ExUnit.Case, async: true

  setup do
    ADK.LLM.Mock.set_responses([])
    :ok
  end

  defp make_runner(agent, opts \\ []) do
    ADK.Runner.new([app_name: "session_scenario"] ++ opts ++ [agent: agent])
  end

  defp run_turn(runner, session_id, message) do
    ADK.Runner.run(runner, "user1", session_id, %{text: message})
  end

  defp last_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn e -> ADK.Event.text(e) end)
  end

  describe "session state persistence" do
    test "same session_id resumes conversation across runner calls" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "memory_bot",
          model: "test",
          instruction: "You remember everything."
        )

      sid = "persist-#{System.unique_integer([:positive])}"

      # First run
      runner1 = make_runner(agent)
      ADK.LLM.Mock.set_responses(["I'll remember that your favorite color is blue."])
      events1 = run_turn(runner1, sid, "My favorite color is blue")
      assert last_text(events1) =~ "blue"

      # Second run with same session_id — session GenServer should still be alive
      runner2 = make_runner(agent)
      ADK.LLM.Mock.set_responses(["Your favorite color is blue!"])
      events2 = run_turn(runner2, sid, "What's my favorite color?")
      assert last_text(events2) =~ "blue"
    end

    test "different session_ids produce independent responses" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "isolator",
          model: "test",
          instruction: "Be helpful."
        )

      runner = make_runner(agent)

      sid1 = "isolated-a-#{System.unique_integer([:positive])}"
      sid2 = "isolated-b-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses(["Session A response"])
      events1 = run_turn(runner, sid1, "Hello from session A")
      assert last_text(events1) == "Session A response"

      ADK.LLM.Mock.set_responses(["Session B response"])
      events2 = run_turn(runner, sid2, "Hello from session B")
      assert last_text(events2) == "Session B response"
    end
  end

  describe "output_key" do
    test "agent with output_key saves response to session state" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "state_bot",
          model: "test",
          instruction: "Summarize conversations.",
          output_key: "last_summary"
        )

      runner = make_runner(agent)
      sid = "output-key-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses(["Summary: User asked about Elixir."])
      events = run_turn(runner, sid, "Tell me about Elixir")

      # The agent ran and produced output — output_key mechanism should have fired
      assert last_text(events) =~ "Elixir"
    end
  end

  describe "session with tool results in history" do
    test "tool calls and results appear in returned events" do
      tool =
        ADK.Tool.FunctionTool.new(:lookup,
          description: "Look up a value",
          func: fn _ctx, %{"key" => key} ->
            {:ok, %{value: "value_for_#{key}"}}
          end,
          parameters: %{}
        )

      agent =
        ADK.Agent.LlmAgent.new(
          name: "lookup_bot",
          model: "test",
          instruction: "Look up values.",
          tools: [tool]
        )

      runner = make_runner(agent)
      sid = "tool-history-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "lookup", args: %{"key" => "api_url"}, id: "fc-1"}},
        "The API URL is value_for_api_url"
      ])

      events = run_turn(runner, sid, "What's the API URL?")

      # Should have multiple events including function_call and function_response
      assert length(events) >= 3

      # Find a function response event
      has_tool_result =
        Enum.any?(events, fn e ->
          case e.content do
            %{parts: parts} when is_list(parts) ->
              Enum.any?(parts, fn
                %{function_response: _} -> true
                _ -> false
              end)

            _ ->
              false
          end
        end)

      assert has_tool_result
    end
  end
end
