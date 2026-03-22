defmodule ADK.Flows.LLMFlows.ProgressiveSSEStreamingParityTest do
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Runner
  alias ADK.Tool.FunctionTool
  alias ADK.LLM.Mock

  @moduledoc """
  Parity tests for Python's `test_progressive_sse_streaming.py`.

  Currently, ADK Elixir handles `partial: true` responses from the LLM backend
  by emitting the partial event and halting the execution loop. It does NOT
  automatically aggregate chunks yet, but we can verify that the behavior
  for individual partial chunks matches expectations (e.g. partial function
  calls are not executed prematurely).
  """

  setup do
    Application.put_env(:adk, :llm_backend, Mock)
    on_exit(fn -> Application.delete_env(:adk, :llm_backend) end)
    :ok
  end

  def track_execution(_ctx, %{"call_id" => call_id}) do
    executions = Process.get(:test_executions, [])
    Process.put(:test_executions, [call_id | executions])
    {:ok, "Executed: #{call_id}"}
  end

  test "partial_function_calls_not_executed_in_none_streaming_mode" do
    # This verifies the equivalent of `test_partial_function_calls_not_executed_in_none_streaming_mode`.
    # When a model returns a partial function call, it should be emitted as a partial event
    # and NOT trigger tool execution immediately.

    Process.put(:test_executions, [])

    Mock.set_responses([
      %{
        partial: true,
        content: %{
          role: :model,
          parts: [
            %{
              function_call: %{
                name: "track_execution",
                args: %{"call_id" => "partial_1"}
              }
            }
          ]
        }
      }
    ])

    tool = FunctionTool.new("track_execution", func: &track_execution/2)
    agent = LlmAgent.new(name: "test_agent", model: "test", instruction: "hi", tools: [tool])
    runner = Runner.new(app_name: "test_app", agent: agent)

    events = Runner.run(runner, "user1", "sess1", "test partial fc handling")

    # Verify the tool was NEVER executed (because it was partial)
    assert Process.get(:test_executions, []) == []

    # Verify the partial event was returned
    assert length(events) == 1
    event = hd(events)
    assert event.partial == true
    assert event.author == "test_agent"
    assert hd(event.content.parts).function_call.name == "track_execution"
  end

  test "progressive_sse_streaming_function_calls (simulated final)" do
    # In Python this aggregates partials into a final event, then executes it.
    # In Elixir, since aggregation isn't built into the runner yet, we test the
    # terminal state: a final (partial: false) event triggers tool execution.

    Process.put(:test_executions, [])

    Mock.set_responses([
      %{
        partial: false,
        content: %{
          role: :model,
          parts: [
            %{text: "Checking weather..."},
            %{function_call: %{name: "track_execution", args: %{"call_id" => "tokyo"}}},
            %{function_call: %{name: "track_execution", args: %{"call_id" => "new_york"}}}
          ]
        }
      },
      "Task completed."
    ])

    tool = FunctionTool.new("track_execution", func: &track_execution/2)
    agent = LlmAgent.new(name: "weather_agent", model: "test", instruction: "hi", tools: [tool])
    runner = Runner.new(app_name: "test_app", agent: agent)

    events = Runner.run(runner, "user1", "sess2", "What is the weather?")

    # Both tools should have executed
    executed = Process.get(:test_executions, [])
    assert "tokyo" in executed
    assert "new_york" in executed

    # We should have multiple events (the model event with the FC, the tool responses, the final text)
    texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
    assert "Task completed." in texts
  end

  test "progressive_sse_preserves_part_ordering" do
    # Simulates the final output after aggregation (which we just return from Mock)
    # ensuring that thoughts and text parts remain ordered and present.

    Mock.set_responses([
      %{
        partial: false,
        content: %{
          role: :model,
          parts: [
            %{text: "Initial thought part", thought: true},
            %{text: "Let me check"},
            %{function_call: %{name: "track_execution", args: %{"call_id" => "tokyo"}}},
            %{text: "Second thought part", thought: true},
            %{function_call: %{name: "track_execution", args: %{"call_id" => "new_york"}}}
          ]
        }
      },
      "Done"
    ])

    tool = FunctionTool.new("track_execution", func: &track_execution/2)
    agent = LlmAgent.new(name: "ordering_agent", model: "test", instruction: "hi", tools: [tool])
    runner = Runner.new(app_name: "test_app", agent: agent)

    events = Runner.run(runner, "user1", "sess3", "What is the weather?")

    # Find the first model event
    model_event = Enum.find(events, &(&1.author == "ordering_agent" && has_function_calls?(&1)))
    assert model_event != nil

    parts = model_event.content.parts
    assert length(parts) == 5

    assert hd(parts)[:thought] == true
    assert hd(parts).text == "Initial thought part"

    assert Enum.at(parts, 1)[:thought] == nil
    assert Enum.at(parts, 1).text == "Let me check"

    assert Enum.at(parts, 2).function_call.name == "track_execution"
    assert Enum.at(parts, 3)[:thought] == true
    assert Enum.at(parts, 4).function_call.name == "track_execution"
  end

  test "run_streaming yields partial events incrementally" do
    Mock.set_responses([
      %{
        partial: true,
        content: %{
          role: :model,
          parts: [%{text: "Chunk 1"}]
        }
      }
    ])

    agent = LlmAgent.new(name: "stream_agent", model: "test", instruction: "stream")
    runner = Runner.new(app_name: "stream_app", agent: agent)

    test_pid = self()

    events =
      Runner.run_streaming(runner, "user2", "session2", "start stream",
        on_event: fn event ->
          send(test_pid, {:stream_chunk, event})
        end,
        stop_session: true
      )

    assert length(events) == 1
    assert hd(events).partial == true
    assert ADK.Event.text(hd(events)) == "Chunk 1"

    assert_receive {:stream_chunk, received_event}, 500
    assert received_event.partial == true
    assert ADK.Event.text(received_event) == "Chunk 1"
  end

  defp has_function_calls?(event) do
    Enum.any?(event.content.parts || [], fn p -> Map.has_key?(p, :function_call) end)
  end
end
