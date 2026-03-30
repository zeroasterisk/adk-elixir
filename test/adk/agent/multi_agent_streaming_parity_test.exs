defmodule ADK.Agent.MultiAgentStreamingParityTest do
  @moduledoc """
  Parity tests for Python ADK's `test_multi_agent_streaming.py`.

  Key parity divergences:
  1. Realtime streaming (WebSocket/VAD audio) is explicitly OMITTED from the Elixir ADK
     roadmap (`run_live`, `LiveRequestQueue`, and audio chunks are not ported).
  2. Python's `test_live_streaming_multi_agent_single_tool` tests multi-agent transfer
     under `run_live`. Since Elixir does not have `run_live`, we instead test multi-agent
     transfer under Elixir's normal `run_streaming` text-streaming interface.
  3. Python's `test_live_streaming_connection_error_on_connect` is omitted as it
     specifically tests Websocket ConnectionClosed exceptions which don't apply.
  4. Elixir ADK uses sticky-agent semantics for transfers (returns control to caller
     on transfer), unlike Python which runs the sub-agent in the same invocation.
     This test covers the multi-turn streaming interaction required to complete the
     delegated tool call.
  """

  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Runner
  alias ADK.Tool.FunctionTool

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "streaming multi-agent single tool (parity: test_live_streaming_multi_agent_single_tool)" do
    test "run_streaming successfully handles agent delegation and tool calls" do
      # --- 1. Mock LLM Responses ---

      # Step 1: Root agent delegates to roll_agent
      delegation_to_roll_agent = %{
        content: %{
          role: "model",
          parts: [
            %{
              function_call: %{
                name: "transfer_to_agent",
                args: %{"agent_name" => "roll_agent"}
              }
            }
          ]
        }
      }

      # Step 2: Roll agent calls roll_die
      function_call_roll_die = %{
        content: %{
          role: "model",
          parts: [
            %{
              function_call: %{
                name: "roll_die",
                args: %{"sides" => 20}
              }
            }
          ]
        }
      }

      # Step 3: Roll agent final response
      final_roll_response = %{
        content: %{
          role: "model",
          parts: [%{text: "I rolled a 15."}]
        }
      }

      ADK.LLM.Mock.set_responses([
        delegation_to_roll_agent,
        function_call_roll_die,
        final_roll_response
      ])

      # --- 2. Mock Tools and Agents ---

      roll_die_tool =
        FunctionTool.new(:roll_die,
          func: fn _tool_ctx, %{"sides" => _sides} ->
            %{"result" => 15}
          end,
          description: "Rolls a die",
          parameters: %{
            "type" => "object",
            "properties" => %{"sides" => %{"type" => "integer"}}
          }
        )

      mock_roll_sub_agent =
        LlmAgent.new(
          name: "roll_agent",
          model: "mock-model",
          tools: [roll_die_tool]
        )

      main_agent =
        LlmAgent.new(
          name: "root_agent",
          model: "mock-model",
          sub_agents: [mock_roll_sub_agent]
        )

      # --- 3. Test Runner Setup ---

      runner = Runner.new(app_name: "test_stream", agent: main_agent)
      user_id = unique_id("user")
      session_id = unique_id("sess")

      test_pid = self()

      on_event = fn event ->
        send(test_pid, {:streamed_event, event})
      end

      # --- 4. Run and Assert ---

      events_turn1 =
        Runner.run_streaming(runner, user_id, session_id, "Roll a 20-sided die",
          on_event: on_event
        )

      # Wait a moment for all events to be processed
      :timer.sleep(50)

      events_turn2 =
        Runner.run_streaming(runner, user_id, session_id, "do it", on_event: on_event)

      :timer.sleep(50)

      # Collect all events sent to test process via streaming callback
      streamed_events = collect_events([])

      # Verify that both return values AND streamed events contain the necessary data
      for all_events <- [events_turn1 ++ events_turn2, streamed_events] do
        delegation_found =
          Enum.any?(all_events, fn ev ->
            parts =
              Map.get(ev.content || %{}, "parts") || Map.get(ev.content || %{}, :parts) || []

            Enum.any?(parts, fn p ->
              fc = Map.get(p, "function_call") || Map.get(p, :function_call) || %{}

              Map.get(fc, "name") == "transfer_to_agent" ||
                Map.get(fc, :name) == "transfer_to_agent"
            end)
          end)

        tool_call_found =
          Enum.any?(all_events, fn ev ->
            parts =
              Map.get(ev.content || %{}, "parts") || Map.get(ev.content || %{}, :parts) || []

            Enum.any?(parts, fn p ->
              fc = Map.get(p, "function_call") || Map.get(p, :function_call) || %{}
              Map.get(fc, "name") == "roll_die" || Map.get(fc, :name) == "roll_die"
            end)
          end)

        tool_response_found =
          Enum.any?(all_events, fn ev ->
            parts =
              Map.get(ev.content || %{}, "parts") || Map.get(ev.content || %{}, :parts) || []

            Enum.any?(parts, fn p ->
              fr = Map.get(p, "function_response") || Map.get(p, :function_response) || %{}
              Map.get(fr, "name") == "roll_die" || Map.get(fr, :name) == "roll_die"
            end)
          end)

        assert delegation_found, "A function_call event for delegation was not found."
        assert tool_call_found, "A function_call event for roll_die was not found."
        assert tool_response_found, "A function_response for roll_die was not found."
      end
    end
  end

  defp collect_events(acc) do
    receive do
      {:streamed_event, event} -> collect_events([event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
