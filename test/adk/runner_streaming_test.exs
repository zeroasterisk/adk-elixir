defmodule ADK.Runner.StreamingTest do
  use ExUnit.Case, async: false

  describe "run_streaming/5" do
    test "calls on_event for each event as it's produced" do
      ADK.LLM.Mock.set_responses(["Hello streaming!"])

      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = ADK.Runner.new(app_name: "stream_test", agent: agent)

      test_pid = self()

      events =
        ADK.Runner.run_streaming(runner, "user1", "stream-sess-1", "Hi",
          on_event: fn event ->
            send(test_pid, {:streamed_event, event})
          end,
          stop_session: true
        )

      # Should return events list
      assert is_list(events)
      assert length(events) >= 1

      # Should have received events via callback
      streamed =
        Enum.reduce_while(1..10, [], fn _, acc ->
          receive do
            {:streamed_event, event} -> {:cont, [event | acc]}
          after
            100 -> {:halt, acc}
          end
        end)
        |> Enum.reverse()

      assert length(streamed) >= 1
      texts = Enum.map(streamed, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "Hello streaming!" in texts
    end

    test "on_event receives events incrementally during multi-turn execution" do
      # Set up agent with tool call to force multiple events
      ADK.LLM.Mock.set_responses([
        # First response: tool call
        %{content: %{parts: [%{function_call: %{name: "get_time", args: %{}}}]}},
        # Second response: final answer
        "The time is now!"
      ])

      get_time =
        ADK.Tool.FunctionTool.new("get_time",
          description: "Get current time",
          func: fn _ctx, _args -> {:ok, "12:00 PM"} end
        )

      agent =
        ADK.Agent.LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Help with time",
          tools: [get_time]
        )

      runner = ADK.Runner.new(app_name: "stream_test", agent: agent)
      test_pid = self()
      event_times = :ets.new(:event_times, [:ordered_set, :public])

      events =
        ADK.Runner.run_streaming(runner, "user1", "stream-sess-2", "What time is it?",
          on_event: fn event ->
            :ets.insert(event_times, {System.monotonic_time(), event})
            send(test_pid, {:streamed_event, event})
          end,
          stop_session: true
        )

      # Should have multiple events (LLM response + tool response + final)
      assert length(events) >= 2

      # Collect streamed events
      streamed =
        Enum.reduce_while(1..20, [], fn _, acc ->
          receive do
            {:streamed_event, event} -> {:cont, [event | acc]}
          after
            100 -> {:halt, acc}
          end
        end)
        |> Enum.reverse()

      assert length(streamed) >= 2
      :ets.delete(event_times)
    end
  end

  describe "Session.subscribe/1" do
    test "subscriber receives events appended to session" do
      {:ok, pid} =
        ADK.Session.start_supervised(
          app_name: "sub_test",
          user_id: "u1",
          session_id: "sub-sess-#{System.unique_integer([:positive])}"
        )

      ADK.Session.subscribe(pid)

      event = ADK.Event.new(%{author: "test", content: %{parts: [%{text: "hello"}]}})
      ADK.Session.append_event(pid, event)

      assert_receive {:adk_session_event, received_event}, 1000
      assert received_event.author == "test"

      GenServer.stop(pid)
    end

    test "unsubscribe stops event delivery" do
      {:ok, pid} =
        ADK.Session.start_supervised(
          app_name: "sub_test",
          user_id: "u1",
          session_id: "unsub-sess-#{System.unique_integer([:positive])}"
        )

      ADK.Session.subscribe(pid)
      ADK.Session.unsubscribe(pid)

      event = ADK.Event.new(%{author: "test", content: %{parts: [%{text: "hello"}]}})
      ADK.Session.append_event(pid, event)

      refute_receive {:adk_session_event, _}, 200

      GenServer.stop(pid)
    end
  end
end
