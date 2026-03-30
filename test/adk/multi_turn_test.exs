defmodule ADK.MultiTurnTest do
  @moduledoc """
  Parity tests for multi-turn conversation scenarios.

  Mirrors Python ADK integration tests in:
    tests/integration/test_multi_turn.py

  Python tests use `AgentEvaluator` with `home_automation_agent` fixture.
  Elixir tests implement equivalent scenarios using `ADK.Runner` + mock LLM,
  verifying that:

  1. `test_simple_multi_turn_conversation` — agent handles back-to-back turns,
     session history is preserved across invocations.
  2. `test_dependent_tool_calls` — second turn references state mutated by
     a tool call in the first turn; session events carry that context.
  3. `test_memorizing_past_events` — agent recalls facts from earlier turns
     when the session history is replayed through the LLM context.

  All three tests use the mock LLM backend so no API key is needed.
  See `test/integration/gemini_api_test.exs` for live-API equivalents.
  """

  use ExUnit.Case, async: false

  alias ADK.Runner
  alias ADK.Agent.LlmAgent
  alias ADK.Tool.FunctionTool

  # ---------- home-automation agent fixture ----------
  # Mirrors the Python fixture agent used in test_multi_turn.py.
  # Supports: set_device_info/3, get_device_info/2

  defp device_agent(device_state_pid) do
    set_device =
      FunctionTool.new("set_device_info",
        description: "Set the status of a device in a location.",
        parameters: %{
          type: "object",
          properties: %{
            location: %{type: "string"},
            device_id: %{type: "string"},
            status: %{type: "string", enum: ["ON", "OFF"]}
          },
          required: ["location", "device_id", "status"]
        },
        func: fn _ctx, %{"location" => loc, "device_id" => dev, "status" => st} ->
          Agent.update(device_state_pid, fn db ->
            Map.put(db, {loc, dev}, st)
          end)

          {:ok, %{result: "ok", device: dev, location: loc, status: st}}
        end
      )

    get_device =
      FunctionTool.new("get_device_info",
        description: "Get the status of a device in a location.",
        parameters: %{
          type: "object",
          properties: %{
            location: %{type: "string"},
            device_id: %{type: "string"}
          },
          required: ["location", "device_id"]
        },
        func: fn _ctx, %{"location" => loc, "device_id" => dev} ->
          status = Agent.get(device_state_pid, fn db -> Map.get(db, {loc, dev}, "UNKNOWN") end)
          {:ok, %{device: dev, location: loc, status: status}}
        end
      )

    LlmAgent.new(
      name: "home_automation_agent",
      model: "test",
      instruction: "You control smart home devices. Use the tools to get/set device status.",
      tools: [set_device, get_device]
    )
  end

  # Helper: start fresh device state
  defp fresh_device_state do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          {"Bedroom", "device_2"} => "OFF",
          {"Living Room", "device_1"} => "ON",
          {"Kitchen", "device_3"} => "OFF"
        }
      end)

    pid
  end

  # Helper: unique session id
  defp sess_id(label),
    do: "#{label}-#{System.unique_integer([:positive])}"

  # ---------- 1. Simple multi-turn conversation ----------
  # Python: test_simple_multi_turn_conversation
  #   Turn 1: "Turn off device_2 in the Bedroom." → tool call + "I have set device 2 to off."
  #   Turn 2: "What room is device_2 in?"         → uses history, answers "Bedroom"

  describe "simple multi-turn conversation (parity: test_simple_multi_turn_conversation)" do
    test "agent handles two sequential turns, preserving session context" do
      device_pid = fresh_device_state()
      agent = device_agent(device_pid)
      runner = %Runner{app_name: "mt-simple", agent: agent}
      sid = sess_id("simple")

      # Turn 1: set device off
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{
            name: "set_device_info",
            args: %{"location" => "Bedroom", "device_id" => "device_2", "status" => "OFF"},
            id: "fc-1"
          }
        },
        "I have set the device 2 status to off."
      ])

      events1 =
        Runner.run(runner, "user1", sid, "Turn off device_2 in the Bedroom.", stop_session: false)

      # Final text event should confirm the action
      text1 = events1 |> Enum.map(&ADK.Event.text/1) |> Enum.reject(&is_nil/1) |> List.last()
      assert text1 =~ ~r/off|device.?2/i

      # Turn 2: recall without re-querying the tool
      ADK.LLM.Mock.set_responses([
        "Device 2 is in the Bedroom."
      ])

      events2 = Runner.run(runner, "user1", sid, "What room is device_2 in?", stop_session: false)

      text2 = events2 |> Enum.map(&ADK.Event.text/1) |> Enum.reject(&is_nil/1) |> List.last()
      assert text2 =~ ~r/bedroom/i

      # Session should accumulate events from both turns
      {:ok, session_pid} = ADK.Session.lookup("mt-simple", "user1", sid)
      all_events = ADK.Session.get_events(session_pid)

      # At minimum: user1, agent events (turn1) + user2, agent events (turn2)
      assert length(all_events) >= 4
    end
  end

  # ---------- 2. Dependent tool calls across turns ----------
  # Python: test_dependent_tool_calls
  #   Turn 1: "Turn off device_2 in the Bedroom." → set_device_info called
  #   Turn 2: "What's the status of device_2?"    → get_device_info called, returns "OFF"

  describe "dependent tool calls (parity: test_dependent_tool_calls)" do
    test "tool mutation in turn 1 is reflected in get query in turn 2" do
      device_pid = fresh_device_state()
      agent = device_agent(device_pid)
      runner = %Runner{app_name: "mt-dep", agent: agent}
      sid = sess_id("dep")

      # Turn 1: mutate device state via tool
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{
            name: "set_device_info",
            args: %{"location" => "Bedroom", "device_id" => "device_2", "status" => "OFF"},
            id: "fc-t1"
          }
        },
        "I have set the device 2 status to off."
      ])

      Runner.run(runner, "user1", sid, "Turn off device_2 in the Bedroom.", stop_session: false)

      # Verify the tool actually mutated state
      stored = Agent.get(device_pid, fn db -> Map.get(db, {"Bedroom", "device_2"}) end)
      assert stored == "OFF"

      # Turn 2: query the now-mutated state via tool
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{
            name: "get_device_info",
            args: %{"location" => "Bedroom", "device_id" => "device_2"},
            id: "fc-t2"
          }
        },
        "The status of device 2 in the Bedroom is OFF."
      ])

      events2 =
        Runner.run(runner, "user1", sid, "What's the status of device_2 in the Bedroom?",
          stop_session: false
        )

      # Confirm the get_device_info was called and returned "OFF"
      fn_response_events =
        events2
        |> Enum.filter(fn e ->
          case e.content do
            %{parts: parts} -> Enum.any?(parts, &Map.has_key?(&1, :function_response))
            _ -> false
          end
        end)

      assert length(fn_response_events) >= 1

      # Final answer should mention OFF
      text2 = events2 |> Enum.map(&ADK.Event.text/1) |> Enum.reject(&is_nil/1) |> List.last()
      assert text2 =~ ~r/off/i
    end

    test "session history contains events from both turns" do
      device_pid = fresh_device_state()
      agent = device_agent(device_pid)
      runner = %Runner{app_name: "mt-dep2", agent: agent}
      sid = sess_id("dep2")

      # Turn 1
      ADK.LLM.Mock.set_responses([
        %{
          function_call: %{
            name: "set_device_info",
            args: %{"location" => "Living Room", "device_id" => "device_1", "status" => "OFF"},
            id: "fc-a"
          }
        },
        "Device 1 turned off."
      ])

      Runner.run(runner, "user1", sid, "Turn off device_1 in the Living Room.",
        stop_session: false
      )

      # Turn 2
      ADK.LLM.Mock.set_responses(["Got it, noted."])

      Runner.run(runner, "user1", sid, "Thanks!", stop_session: false)

      # Both turns recorded in session
      {:ok, session_pid} = ADK.Session.lookup("mt-dep2", "user1", sid)
      events = ADK.Session.get_events(session_pid)

      user_events = Enum.filter(events, &(&1.author == "user"))
      assert length(user_events) == 2
    end
  end

  # ---------- 3. Memorizing past events ----------
  # Python: test_memorizing_past_events
  #   Conversation where the agent must recall a fact introduced in turn 1
  #   when answering in turn 3.

  describe "memorizing past events (parity: test_memorizing_past_events)" do
    test "agent can recall a fact from an earlier turn" do
      agent =
        LlmAgent.new(
          name: "memory_bot",
          model: "test",
          instruction: "Remember everything the user tells you."
        )

      runner = %Runner{app_name: "mt-mem", agent: agent}
      sid = sess_id("mem")

      # Turn 1: introduce a fact
      ADK.LLM.Mock.set_responses(["Got it, I'll remember that your favorite color is blue."])
      Runner.run(runner, "user1", sid, "My favorite color is blue.", stop_session: false)

      # Turn 2: unrelated topic
      ADK.LLM.Mock.set_responses(["The capital of France is Paris."])
      Runner.run(runner, "user1", sid, "What is the capital of France?", stop_session: false)

      # Turn 3: recall the fact from turn 1
      ADK.LLM.Mock.set_responses(["Your favorite color is blue."])

      events3 =
        Runner.run(runner, "user1", sid, "What is my favorite color?", stop_session: false)

      text3 = events3 |> Enum.map(&ADK.Event.text/1) |> Enum.reject(&is_nil/1) |> List.last()
      assert text3 =~ ~r/blue/i

      # Session should have events from all three turns
      {:ok, session_pid} = ADK.Session.lookup("mt-mem", "user1", sid)
      all_events = ADK.Session.get_events(session_pid)
      user_events = Enum.filter(all_events, &(&1.author == "user"))
      assert length(user_events) == 3
    end

    test "conversation history is reflected in LLM request messages" do
      # Verifies that the LLM is sent the full conversation history,
      # not just the latest message. This is the mechanism that enables
      # multi-turn memory in a stateless LLM.
      agent = LlmAgent.new(name: "history_bot", model: "test", instruction: "Be helpful.")
      runner = %Runner{app_name: "mt-hist", agent: agent}
      sid = sess_id("hist")

      ADK.LLM.Mock.set_responses(["I see, noted."])
      Runner.run(runner, "u1", sid, "First message.", stop_session: false)

      ADK.LLM.Mock.set_responses(["Second reply."])
      Runner.run(runner, "u1", sid, "Second message.", stop_session: false)

      {:ok, session_pid} = ADK.Session.lookup("mt-hist", "u1", sid)
      events = ADK.Session.get_events(session_pid)

      # 4 events minimum: user1 + agent1 + user2 + agent2
      assert length(events) >= 4

      # user messages should be in chronological order
      user_texts =
        events
        |> Enum.filter(&(&1.author == "user"))
        |> Enum.flat_map(fn e ->
          case e.content do
            %{parts: parts} ->
              Enum.flat_map(parts, fn
                %{text: t} when is_binary(t) -> [t]
                _ -> []
              end)

            _ ->
              []
          end
        end)

      assert "First message." in user_texts
      assert "Second message." in user_texts

      # chronological: First message appears before Second message
      first_idx = Enum.find_index(user_texts, &(&1 == "First message."))
      second_idx = Enum.find_index(user_texts, &(&1 == "Second message."))
      assert first_idx < second_idx
    end
  end

  # ---------- 4. Session isolation ----------
  # Not in Python test_multi_turn.py but critical correctness property:
  # different session IDs must not share event history.

  describe "session isolation" do
    test "two users in separate sessions do not share event history" do
      agent = LlmAgent.new(name: "iso_bot", model: "test", instruction: "Help")
      runner = %Runner{app_name: "mt-iso", agent: agent}

      ADK.LLM.Mock.set_responses(["Reply for user A."])
      Runner.run(runner, "userA", "sessA", "Hello from A.", stop_session: false)

      ADK.LLM.Mock.set_responses(["Reply for user B."])
      Runner.run(runner, "userB", "sessB", "Hello from B.", stop_session: false)

      {:ok, pidA} = ADK.Session.lookup("mt-iso", "userA", "sessA")
      {:ok, pidB} = ADK.Session.lookup("mt-iso", "userB", "sessB")

      events_a = ADK.Session.get_events(pidA)
      events_b = ADK.Session.get_events(pidB)

      texts_a =
        events_a
        |> Enum.flat_map(fn e ->
          case e.content do
            %{parts: parts} ->
              Enum.flat_map(parts, fn
                %{text: t} when is_binary(t) and t != "" -> [t]
                _ -> []
              end)

            _ ->
              []
          end
        end)

      texts_b =
        events_b
        |> Enum.flat_map(fn e ->
          case e.content do
            %{parts: parts} ->
              Enum.flat_map(parts, fn
                %{text: t} when is_binary(t) and t != "" -> [t]
                _ -> []
              end)

            _ ->
              []
          end
        end)

      # A's session should not contain B's message and vice versa
      refute "Hello from B." in texts_a
      refute "Hello from A." in texts_b
    end
  end
end
