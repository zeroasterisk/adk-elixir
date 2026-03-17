defmodule ADK.InvocationContextTest.TestingUtils do
  defmacro __using__(_) do
    quote do
      alias ADK.Agent.LlmAgent
      alias ADK.Events.Event
      alias ADK.Sessions.Session

      defp mock_agent(name) do
        %ADK.Agent.LlmAgent{name: name, sub_agents: []}
      end

      defp mock_session(events) do
        %Session{id: "session_123", events: events}
      end

      defp mock_event(invocation_id, branch) do
        %Event{
          invocation_id: invocation_id,
          branch: branch,
          author: "agent",
          content: %Google.AI.Generativelanguage.V1beta.Content{role: "model", parts: []}
        }
      end

      defp mock_invocation_context(events, invocation_id, branch) do
        %ADK.Agents.InvocationContext{
          session_service: nil,
          agent: mock_agent("test_agent"),
          invocation_id: invocation_id,
          branch: branch,
          session: mock_session(events)
        }
      end
    end
  end
end

defmodule ADK.InvocationContextTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Agents.BaseAgentState
  alias ADK.Agents.InvocationContext
  alias ADK.Apps.ResumabilityConfig
  alias ADK.Events.Event
  alias ADK.Events.EventActions
  alias Google.Protobuf.Struct
  alias Google.AI.Generativelanguage.V1beta.Content
  alias Google.AI.Generativelanguage.V1beta.FunctionCall
  alias Google.AI.Generativelanguage.V1beta.FunctionResponse
  alias Google.AI.Generativelanguage.V1beta.Part

  use ADK.InvocationContextTest.TestingUtils

  describe "_get_events" do
    setup do
      events = [
        mock_event("inv_1", "agent_1"),
        mock_event("inv_1", "agent_2"),
        mock_event("inv_2", "agent_1"),
        mock_event("inv_2", "agent_2")
      ]

      ctx = mock_invocation_context(events, "inv_1", "agent_1")
      %{ctx: ctx, events: events}
    end

    test "returns all events by default", %{ctx: ctx, events: events} do
      assert InvocationContext._get_events(ctx) == events
    end

    test "filters by current invocation", %{ctx: ctx, events: events} do
      [event1, event2 | _] = events

      assert InvocationContext._get_events(ctx, current_invocation: true) == [event1, event2]
    end

    test "filters by current branch", %{ctx: ctx, events: events} do
      [event1, _, event3 | _] = events
      assert InvocationContext._get_events(ctx, current_branch: true) == [event1, event3]
    end

    test "filters by invocation and branch", %{ctx: ctx, events: events} do
      [event1 | _] = events

      assert InvocationContext._get_events(ctx, current_invocation: true, current_branch: true) == [
               event1
             ]
    end

    test "with no events in session", %{ctx: ctx} do
      ctx = %{ctx | session: mock_session([])}
      assert InvocationContext._get_events(ctx) == []
    end

    test "with no matching events", %{ctx: ctx} do
      ctx = %{ctx | invocation_id: "inv_3", branch: "branch_C"}
      assert InvocationContext._get_events(ctx, current_invocation: true) == []
      assert InvocationContext._get_events(ctx, current_branch: true) == []

      assert InvocationContext._get_events(ctx, current_invocation: true, current_branch: true) ==
               []
    end
  end

  defp create_test_invocation_context(resumability_config) do
    %InvocationContext{
      session_service: nil,
      agent: mock_agent("test_agent"),
      invocation_id: "inv_1",
      session: mock_session([]),
      resumability_config: resumability_config
    }
  end

  defp long_running_function_call do
    %FunctionCall{
      name: "long_running_function_call",
      args: %Struct{fields: %{}}
    }
  end

  defp event_to_pause(long_running_function_call) do
    %Event{
      invocation_id: "inv_1",
      author: "agent",
      content: %Content{
        role: "model",
        parts: [%Part{data: {:function_call, long_running_function_call}, mime_type: ""}]
      },
      long_running_tool_ids: ["tool_call_id_1"]
    }
  end

  describe "should_pause_invocation" do
    test "with a resumable app" do
      ctx = create_test_invocation_context(%ResumabilityConfig{is_resumable: true})
      fc = long_running_function_call()
      event = event_to_pause(fc)
      assert InvocationContext.should_pause_invocation(ctx, event)
    end

    test "with a non-resumable app" do
.
.
.
      refute "sub_sub_agent_1" in Map.keys(new_ctx.end_of_agents)
    end
  end

  describe "find_matching_function_call" do
    defp create_fc_event(id, name) do
      fc = %Part{
        data: {:function_call, %FunctionCall{id: id, name: name, args: %Struct{fields: %{}}}},
        mime_type: ""
      }

      %Event{
        invocation_id: "inv_1",
        author: "agent",
        content: %Content{role: "model", parts: [fc]}
      }
    end

    defp create_fr_event(id, name) do
      fr = %Part{
        data:
          {:function_response,
           %FunctionResponse{
             id: id,
             name: name,
             response: %Struct{fields: %{"result" => "ok"}}
           }},
        mime_type: ""
      }

      %Event{
        invocation_id: "inv_1",
        author: "agent",
        content: %Content{role: "user", parts: [fr]}
      }
    end

    test "finds a matching function call" do
      fc_event = create_fc_event("test_function_call_id", "some_tool")
      fr_event = create_fr_event("test_function_call_id", "some_tool")
      ctx = create_test_invocation_context(nil)
      ctx = %{ctx | session: mock_session([fc_event, fr_event])}
      matching_fc_event = InvocationContext._find_matching_function_call(ctx, fr_event)
      assert matching_fc_event.content == fc_event.content
    end

    test "does not find a match if id doesn't match" do
      fc_event = create_fc_event("another_function_call_id", "some_tool")
      fr_event = create_fr_event("test_function_call_id", "some_tool")
      ctx = create_test_invocation_context(nil)
      ctx = %{ctx | session: mock_session([fc_event, fr_event])}
      assert InvocationContext._find_matching_function_call(ctx, fr_event) == nil
    end

    test "does not find a match if there are no call events" do
      fr_event = create_fr_event("test_function_call_id", "some_tool")
      ctx = create_test_invocation_context(nil)
      ctx = %{ctx | session: mock_session([fr_event])}
      assert InvocationContext._find_matching_function_call(ctx, fr_event) == nil
    end

    test "result is None if function_response_event has no function response" do
      fr_event_no_fr = %Event{
        author: "agent",
        content: %Content{role: "user", parts: [%Part{data: {:text, "user message"}, mime_type: ""}]}
      }

      fc_event = create_fc_event("test_function_call_id", "some_tool")
      fr_event = create_fr_event("test_function_call_id", "some_tool")
      ctx = create_test_invocation_context(nil)
      ctx = %{ctx | session: mock_session([fc_event, fr_event])}
      assert InvocationContext._find_matching_function_call(ctx, fr_event_no_fr) == nil
    end
  end
end
