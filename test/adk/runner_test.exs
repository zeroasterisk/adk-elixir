defmodule ADK.RunnerTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([File.cwd!(), "lib/adk/agent/base_agent.ex"]))
  Code.require_file(Path.join([File.cwd!(), "lib/adk/agent/llm_agent.ex"]))

  alias ADK.Agent.BaseAgent
  alias ADK.Agent.InvocationContext
  alias ADK.Agent.LlmAgent
  alias ADK.App
  alias ADK.Event
  alias ADK.Runner
  alias ADK.Session
  alias ADK.Session.InMemorySessionService
  alias ADK.Artifact.InMemoryArtifactService
  alias ADK.Agent.RunConfig
  alias ADK.Session.GetSessionConfig

  defmodule MockAgent do
    @moduledoc false
    use ADK.Agent.BaseAgent, name: "mock_agent"

    @impl true
    def run_async_impl(_invocation_context) do
      Stream.unfold(false, fn
        false ->
          event = %Event{
            author: "mock_agent",
            content: %{role: "model", parts: [%{text: "Test response"}]}
          }
          {event, true}
        true ->
          nil
      end)
    end
  end

  defmodule MockLlmAgent do
    @moduledoc false
    use ADK.Agent.LlmAgent, name: "mock_llm_agent", model: "gemini-1.5-pro"

    @impl true
    def run_async_impl(_invocation_context) do
      Stream.unfold(false, fn
        false ->
          event = %Event{
            author: "mock_llm_agent",
            content: %{role: "model", parts: [%{text: "Test LLM response"}]}
          }
          {event, true}
        true ->
          nil
      end)
    end
  end

  defmodule MockLiveAgent do
    @moduledoc false
    use ADK.Agent.BaseAgent, name: "mock_live_agent"

    @impl true
    def run_live_impl(_invocation_context) do
      Stream.unfold(false, fn
        false ->
          event = %Event{
            author: "mock_live_agent",
            content: %{role: "model", parts: [%{text: "live hello"}]}
          }
          {event, true}
        true ->
          nil
      end)
    end
  end

  defmodule MockAgentWithMetadata do
    @moduledoc false
    use ADK.Agent.BaseAgent, name: "metadata_agent"

    @impl true
    def run_async_impl(invocation_context) do
      Stream.unfold(false, fn
        false ->
          event = %Event{
            invocation_id: invocation_context.invocation_id,
            author: "metadata_agent",
            content: %{role: "model", parts: [%{text: "Test response"}]},
            custom_metadata: %{"event_key" => "event_value"}
          }
          {event, true}
        true ->
          nil
      end)
    end
  end

  setup do
    session_service = InMemorySessionService.new()
    artifact_service = InMemoryArtifactService.new()

    %{
      session_service: session_service,
      artifact_service: artifact_service
    }
  end

  test "session is auto-created when auto_create_session is true", %{session_service: session_service, artifact_service: artifact_service} do
    runner = Runner.new(
      app_name: "test_app",
      agent: MockLlmAgent,
      session_service: session_service,
      artifact_service: artifact_service,
      auto_create_session: true
    )

    events =
      runner
      |> Runner.run_async("user", "missing_session", %{role: "user", parts: [%{text: "hi"}]})
      |> Enum.to_list()

    assert [%Event{author: "mock_llm_agent", content: %{parts: [%{text: "Test LLM response"}]}}] = events

    assert {:ok, _session} = InMemorySessionService.get_session(session_service, "test_app", "user", "missing_session")
  end

  test "run_live auto-creates session and yields events", %{session_service: session_service, artifact_service: artifact_service} do
    runner = Runner.new(
      app_name: "live_app",
      agent: MockLiveAgent,
      session_service: session_service,
      artifact_service: artifact_service,
      auto_create_session: true
    )

    live_queue = ADK.Agent.LiveRequestQueue.new()

    events =
      runner
      |> Runner.run_live("user", "missing_session", live_queue)
      |> Enum.to_list()

    assert [%Event{author: "mock_live_agent", content: %{parts: [%{text: "live hello"}]}}] = events

    assert {:ok, _session} = InMemorySessionService.get_session(session_service, "live_app", "user", "missing_session")
  end

  test "rewind creates session if missing when auto_create_session is true", %{session_service: session_service, artifact_service: artifact_service} do
    runner = Runner.new(
      app_name: "auto_create_app",
      agent: MockLlmAgent,
      session_service: session_service,
      artifact_service: artifact_service,
      auto_create_session: true
    )

    assert_raise(ValueError, ~r/Invocation ID not found: inv_missing/, fn ->
      Runner.rewind_async(runner, "user", "missing_session", "inv_missing")
    end)

    assert {:ok, session} = InMemorySessionService.get_session(session_service, "auto_create_app", "user", "missing_session")
    assert session.app_name == "auto_create_app"
  end

  test "run_async with custom metadata propagates to events", %{session_service: session_service, artifact_service: artifact_service} do
    runner = Runner.new(
      app_name: "test_app",
      agent: MockAgentWithMetadata,
      session_service: session_service,
      artifact_service: artifact_service
    )

    {:ok, _session} = InMemorySessionService.create_session(session_service, "test_app", "user", "test_session")

    run_config = %RunConfig{custom_metadata: %{"request_id" => "req-1"}}

    events =
      runner
      |> Runner.run_async("user", "test_session", %{role: "user", parts: [%{text: "hi"}]}, run_config)
      |> Enum.to_list()

    assert [%Event{custom_metadata: %{"request_id" => "req-1", "event_key" => "event_value"}}] = events

    {:ok, session} = InMemorySessionService.get_session(session_service, "test_app", "user", "test_session")
    user_event = Enum.find(session.events, &(&1.author == "user"))
    assert user_event.custom_metadata == %{"request_id" => "req-1"}
  end

  test "run_async passes get_session_config to get_session", %{session_service: session_service, artifact_service: artifact_service} do
    {:ok, session} = InMemorySessionService.create_session(session_service, "test_app", "user", "test_session")
    for i <- 1..10 do
      InMemorySessionService.append_event(session_service, session, %Event{
        invocation_id: "inv_#{i}",
        author: "user",
        content: %{role: "user", parts: [%{text: "message #{i}"}]}
      })
    end

    runner = Runner.new(
      app_name: "test_app",
      agent: MockAgent,
      session_service: session_service,
      artifact_service: artifact_service
    )

    config = %RunConfig{
      get_session_config: %GetSessionConfig{num_recent_events: 3}
    }

    events =
      runner
      |> Runner.run_async("user", "test_session", %{role: "user", parts: [%{text: "hello"}]}, config)
      |> Enum.to_list()

    assert length(events) >= 1
    assert hd(events).author == "mock_agent"
  end

  test "get_session_config limits events", %{session_service: session_service} do
    {:ok, session} = InMemorySessionService.create_session(session_service, "test_app", "user", "test_session")
    for i <- 1..10 do
      InMemorySessionService.append_event(session_service, session, %Event{
        invocation_id: "inv_#{i}",
        author: "user",
        content: %{role: "user", parts: [%{text: "message #{i}"}]}
      })
    end

    {:ok, full_session} = InMemorySessionService.get_session(session_service, "test_app", "user", "test_session")
    assert length(full_session.events) == 10

    {:ok, limited_session} = InMemorySessionService.get_session(session_service, "test_app", "user", "test_session", %GetSessionConfig{num_recent_events: 3})
    assert length(limited_session.events) == 3
  end
end
