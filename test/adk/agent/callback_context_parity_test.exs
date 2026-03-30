defmodule ADK.Agent.CallbackContextParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's `test_callback_context.py`.

  Python's `CallbackContext` wraps an invocation context and provides access
  to agent info, session state, artifacts, credentials, and memory.
  In Elixir ADK, the callback context is a map `%{agent: agent, context: ctx}`
  threaded through `ADK.Callback` hooks.

  These tests verify:
  - Callback context shape and content during before_agent / after_agent
  - Session state access from callbacks
  - Agent info available in callback context
  - ToolContext state operations (parity with Python's CallbackContext.state)
  - Memory store accessibility through invocation context
  - Artifact/credential service presence propagation
  """
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Event
  alias ADK.Runner
  alias ADK.ToolContext

  # ============================================================================
  # Callback Modules — capture callback context for assertions
  # ============================================================================

  defmodule ContextCapture do
    @moduledoc false
    @behaviour ADK.Callback

    @doc "Captures callback context to the process dictionary and continues."
    @impl true
    def before_agent(cb_ctx) do
      Process.put(:captured_cb_ctx, cb_ctx)
      {:cont, cb_ctx}
    end

    @impl true
    def after_agent(events, cb_ctx) do
      Process.put(:captured_after_cb_ctx, cb_ctx)
      events
    end
  end

  defmodule HaltWithStateCapture do
    @moduledoc false
    @behaviour ADK.Callback

    @doc "Captures state from session via callback context, then halts."
    @impl true
    def before_agent(cb_ctx) do
      ctx = cb_ctx.context

      # Read state from session
      state_value =
        if ctx.session_pid do
          ADK.Session.get_state(ctx.session_pid, "test_key")
        end

      Process.put(:captured_state_value, state_value)

      event =
        Event.new(%{
          author: "callback",
          content: %{parts: [%{text: "halted with state: #{inspect(state_value)}"}]}
        })

      {:halt, [event]}
    end
  end

  defmodule AfterAgentAppendCallback do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def after_agent(events, _cb_ctx) do
      extra =
        Event.new(%{
          author: "callback",
          content: %{parts: [%{text: "appended by after_agent"}]}
        })

      events ++ [extra]
    end
  end

  defmodule StateWriterCallback do
    @moduledoc false
    @behaviour ADK.Callback

    @doc "Writes a test key to session state and continues."
    @impl true
    def before_agent(cb_ctx) do
      ctx = cb_ctx.context

      if ctx.session_pid do
        ADK.Session.put_state(ctx.session_pid, "test_key", "hello_world")
      end

      {:cont, cb_ctx}
    end
  end

  defmodule AgentInfoCapture do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def before_agent(cb_ctx) do
      agent = cb_ctx.agent
      Process.put(:captured_agent_name, ADK.Agent.name(agent))
      Process.put(:captured_agent_description, ADK.Agent.description(agent))

      event =
        Event.new(%{
          author: "callback",
          content: %{parts: [%{text: "agent: #{ADK.Agent.name(agent)}"}]}
        })

      {:halt, [event]}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Event.text/1 expects string-keyed content (known pre-existing issue).
  # This helper safely extracts text from atom- or string-keyed events.
  defp event_text(%Event{content: %{parts: parts}}) when is_list(parts) do
    Enum.find_value(parts, fn
      %{text: t} -> t
      %{"text" => t} -> t
      _ -> nil
    end)
  end

  defp event_text(%Event{content: content}) when is_map(content) do
    case content do
      %{"parts" => parts} ->
        Enum.find_value(parts, fn
          %{"text" => t} -> t
          %{text: t} -> t
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp event_text(_), do: nil

  # ============================================================================
  # Setup
  # ============================================================================

  # No global setup — each test that needs LLM mock sets its own responses
  # to avoid race conditions with async: true

  # ============================================================================
  # Tests: Callback context shape and initialization
  # ============================================================================

  describe "callback context initialization" do
    test "before_agent receives context with agent and invocation context" do
      ADK.LLM.Mock.set_responses(["mock response"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "test_agent",
          instruction: "You are a test agent."
        )

      runner = Runner.new(app_name: "test_app", agent: agent)
      _events = Runner.run(runner, "user1", "cb-ctx-init", "Hello", callbacks: [ContextCapture])

      cb_ctx = Process.get(:captured_cb_ctx)
      assert cb_ctx != nil
      assert is_map(cb_ctx)
      assert Map.has_key?(cb_ctx, :agent)
      assert Map.has_key?(cb_ctx, :context)
    end

    test "callback context contains the correct agent" do
      ADK.LLM.Mock.set_responses(["mock response"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "my_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)
      _events = Runner.run(runner, "user1", "cb-agent-check", "Hi", callbacks: [ContextCapture])

      cb_ctx = Process.get(:captured_cb_ctx)
      assert ADK.Agent.name(cb_ctx.agent) == "my_agent"
    end

    test "callback context contains invocation context with session_pid" do
      ADK.LLM.Mock.set_responses(["mock response"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "session_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)
      _events = Runner.run(runner, "user1", "cb-session", "Hi", callbacks: [ContextCapture])

      cb_ctx = Process.get(:captured_cb_ctx)
      ctx = cb_ctx.context
      assert is_pid(ctx.session_pid)
      assert ctx.invocation_id != nil
    end

    test "after_agent callback receives same context structure" do
      ADK.LLM.Mock.set_responses(["mock response"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "after_agent_test",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)
      _events = Runner.run(runner, "user1", "cb-after", "Hi", callbacks: [ContextCapture])

      after_ctx = Process.get(:captured_after_cb_ctx)
      assert after_ctx != nil
      assert Map.has_key?(after_ctx, :agent)
      assert Map.has_key?(after_ctx, :context)
    end
  end

  # ============================================================================
  # Tests: Agent info access (parity with Python CallbackContext._invocation_context.agent)
  # ============================================================================

  describe "agent info from callback context" do
    test "agent name accessible from callback context" do
      agent =
        LlmAgent.new(
          model: "test-model",
          name: "named_agent",
          description: "A test agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)
      _events = Runner.run(runner, "user1", "cb-info", "Hi", callbacks: [AgentInfoCapture])

      assert Process.get(:captured_agent_name) == "named_agent"
      assert Process.get(:captured_agent_description) == "A test agent"
    end

    test "agent info callback halts with agent name in response" do
      agent =
        LlmAgent.new(
          model: "test-model",
          name: "info_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)
      [event] = Runner.run(runner, "user1", "cb-info2", "Hi", callbacks: [AgentInfoCapture])

      assert event_text(event) == "agent: info_agent"
    end
  end

  # ============================================================================
  # Tests: State access from callback context
  # (Python: CallbackContext.state maps to session.state)
  # ============================================================================

  describe "state access from callback context" do
    test "callback receives context with live session_pid" do
      ADK.LLM.Mock.set_responses(["mock response"])

      # Use a callback that captures state while session is still alive
      # (Runner stops session after run completes)
      agent =
        LlmAgent.new(
          model: "test-model",
          name: "state_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)

      _events =
        Runner.run(runner, "user1", "cb-state-read", "Hi", callbacks: [ContextCapture])

      cb_ctx = Process.get(:captured_cb_ctx)
      ctx = cb_ctx.context

      # Session was alive during callback (pid was set)
      assert is_pid(ctx.session_pid)
    end

    test "callback can read default state for missing key" do
      # HaltWithStateCapture reads "test_key" from session during before_agent
      # When no state is set, it should be nil
      agent =
        LlmAgent.new(
          model: "test-model",
          name: "default_state_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)

      _events =
        Runner.run(runner, "user1", "cb-state-nil", "Hi", callbacks: [HaltWithStateCapture])

      captured = Process.get(:captured_state_value)
      assert captured == nil
    end

    test "callback can write and read session state during execution" do
      # StateWriterCallback writes state, then HaltWithStateCapture reads it
      # Both run in the same before_agent chain
      agent =
        LlmAgent.new(
          model: "test-model",
          name: "write_read_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)

      # StateWriter runs first (writes "test_key"), then HaltWithStateCapture reads it
      _events =
        Runner.run(runner, "user1", "cb-state-write-read", "Hi",
          callbacks: [StateWriterCallback, HaltWithStateCapture]
        )

      captured = Process.get(:captured_state_value)
      assert captured == "hello_world"
    end
  end

  # ============================================================================
  # Tests: After-agent callback transforms events
  # (Python: after_agent can append/modify events)
  # ============================================================================

  describe "after_agent callback event transformation" do
    test "after_agent can append events" do
      ADK.LLM.Mock.set_responses(["mock response"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "append_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)

      events =
        Runner.run(runner, "user1", "cb-append", "Hi", callbacks: [AfterAgentAppendCallback])

      texts = Enum.map(events, &event_text/1)
      assert "appended by after_agent" in texts
    end

    test "after_agent receives events from agent execution" do
      ADK.LLM.Mock.set_responses(["LLM said hello"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "events_check_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)

      events =
        Runner.run(runner, "user1", "cb-events", "Hi", callbacks: [AfterAgentAppendCallback])

      texts = Enum.map(events, &event_text/1)
      assert "LLM said hello" in texts
      assert "appended by after_agent" in texts
      assert length(events) >= 2
    end
  end

  # ============================================================================
  # Tests: ToolContext state operations
  # (Python: ToolContext inherits CallbackContext state access)
  # ============================================================================

  describe "tool context state operations" do
    setup do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "user1",
          session_id: "tc-state-#{System.unique_integer([:positive])}",
          name: nil
        )

      ctx = %ADK.Context{
        invocation_id: "inv-tc-state",
        session_pid: session_pid,
        agent: nil,
        callbacks: [],
        policies: []
      }

      tool = %{name: "test_tool"}
      tc = ToolContext.new(ctx, "call-1", tool)

      on_exit(fn -> Process.alive?(session_pid) && GenServer.stop(session_pid) end)

      %{tc: tc, session_pid: session_pid}
    end

    test "get_state returns nil for missing key", %{tc: tc} do
      assert ToolContext.get_state(tc, "missing_key") == nil
    end

    test "get_state returns default for missing key", %{tc: tc} do
      assert ToolContext.get_state(tc, "missing_key", "default_val") == "default_val"
    end

    test "put_state and get_state roundtrip", %{tc: tc} do
      {:ok, tc} = ToolContext.put_state(tc, "key1", "value1")
      assert ToolContext.get_state(tc, "key1") == "value1"
    end

    test "multiple put_state calls accumulate in state_delta", %{tc: tc} do
      {:ok, tc} = ToolContext.put_state(tc, "k1", "v1")
      {:ok, tc} = ToolContext.put_state(tc, "k2", "v2")
      {:ok, tc} = ToolContext.put_state(tc, "k3", "v3")

      actions = ToolContext.actions(tc)
      assert actions.state_delta == %{"k1" => "v1", "k2" => "v2", "k3" => "v3"}
    end

    test "put_state overwrites previous value for same key", %{tc: tc} do
      {:ok, tc} = ToolContext.put_state(tc, "key", "first")
      {:ok, tc} = ToolContext.put_state(tc, "key", "second")
      assert ToolContext.get_state(tc, "key") == "second"
      assert ToolContext.actions(tc).state_delta == %{"key" => "second"}
    end
  end

  # ============================================================================
  # Tests: Invocation context propagates services
  # (Python: CallbackContext checks artifact_service, credential_service, memory_service)
  # ============================================================================

  describe "invocation context service propagation" do
    test "context without artifact_service propagates to tool context" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "user1",
          session_id: "svc-none-#{System.unique_integer([:positive])}",
          name: nil
        )

      ctx = %ADK.Context{
        invocation_id: "inv-svc",
        session_pid: session_pid,
        agent: nil,
        artifact_service: nil,
        callbacks: [],
        policies: []
      }

      tc = ToolContext.new(ctx, "call-1", %{name: "test_tool"})
      assert {:error, :no_artifact_service} = ToolContext.list_artifacts(tc)
      assert {:error, :no_artifact_service} = ToolContext.load_artifact(tc, "file.txt")

      assert {:error, :no_artifact_service} =
               ToolContext.save_artifact(tc, "file.txt", %{data: "x"})

      GenServer.stop(session_pid)
    end

    test "context without credential_service propagates to tool context" do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "user1",
          session_id: "svc-no-cred-#{System.unique_integer([:positive])}",
          name: nil
        )

      ctx = %ADK.Context{
        invocation_id: "inv-svc-cred",
        session_pid: session_pid,
        agent: nil,
        credential_service: nil,
        callbacks: [],
        policies: []
      }

      tc = ToolContext.new(ctx, "call-1", %{name: "test_tool"})
      assert {:error, :no_credential_service} = ToolContext.load_credential(tc, "api_key")

      GenServer.stop(session_pid)
    end

    test "context without memory_store is nil" do
      ctx = %ADK.Context{
        invocation_id: "inv-mem",
        session_pid: nil,
        agent: nil,
        memory_store: nil,
        callbacks: [],
        policies: []
      }

      assert ctx.memory_store == nil
    end

    test "context with memory_store retains it" do
      ctx = %ADK.Context{
        invocation_id: "inv-mem2",
        session_pid: nil,
        agent: nil,
        memory_store: {ADK.Memory.InMemory, []},
        callbacks: [],
        policies: []
      }

      assert ctx.memory_store == {ADK.Memory.InMemory, []}
    end
  end

  # ============================================================================
  # Tests: Memory store through context
  # (Python: CallbackContext.add_session_to_memory, add_events_to_memory, add_memory)
  # In Elixir, memory_store is on the context; SearchMemoryTool uses it.
  # ============================================================================

  describe "memory store on context" do
    # Note: ADK.Memory.InMemory uses a named ETS table, so these tests
    # ensure the GenServer is started once (via Application or prior test).
    # We use unique app/user scopes to avoid test interference.

    setup do
      # Ensure InMemory GenServer is running (may already be started by Application)
      case ADK.Memory.InMemory.start_link([]) do
        {:ok, pid} -> %{mem_pid: pid}
        {:error, {:already_started, pid}} -> %{mem_pid: pid}
      end
    end

    test "memory store add and search work through module" do
      scope = "cb_ctx_parity_#{System.unique_integer([:positive])}"

      entries = [
        ADK.Memory.Entry.new(content: "User prefers dark mode")
      ]

      :ok = ADK.Memory.InMemory.add(scope, "user1", entries)
      {:ok, results} = ADK.Memory.InMemory.search(scope, "user1", "dark mode")

      assert length(results) > 0
      assert hd(results).content =~ "dark mode"
    end

    test "memory store returns empty for non-matching queries" do
      scope = "cb_ctx_empty_#{System.unique_integer([:positive])}"
      {:ok, results} = ADK.Memory.InMemory.search(scope, "user_empty", "anything")
      assert results == []
    end

    test "memory store add_session converts events to entries" do
      scope = "cb_ctx_session_#{System.unique_integer([:positive])}"

      events = [
        %ADK.Event{
          author: "user",
          content: %{text: "I like pizza"},
          timestamp: DateTime.utc_now()
        },
        %ADK.Event{
          author: "agent",
          content: %{text: "Noted, you like pizza!"},
          timestamp: DateTime.utc_now()
        }
      ]

      :ok = ADK.Memory.InMemory.add_session(scope, "user_session", "sess1", events)
      {:ok, results} = ADK.Memory.InMemory.search(scope, "user_session", "pizza")

      assert length(results) == 2
    end
  end

  # ============================================================================
  # Tests: EventActions initialization
  # (Python: CallbackContext._event_actions is not None)
  # ============================================================================

  describe "event actions initialization" do
    test "event actions starts with empty deltas" do
      actions = %ADK.EventActions{}
      assert actions.state_delta == %{}
      assert actions.artifact_delta == %{}
      assert actions.requested_auth_configs == %{}
      assert actions.transfer_to_agent == nil
      assert actions.escalate == false
    end

    test "tool context starts with empty event actions" do
      ctx = %ADK.Context{
        invocation_id: "inv-ea",
        session_pid: nil,
        agent: nil,
        callbacks: [],
        policies: []
      }

      tc = ToolContext.new(ctx, "call-1", %{name: "test_tool"})
      actions = ToolContext.actions(tc)
      assert actions.state_delta == %{}
      assert actions.artifact_delta == %{}
    end
  end

  # ============================================================================
  # Tests: Callback context through full runner pipeline
  # ============================================================================

  describe "callback context in runner pipeline" do
    test "callback context has correct app_name from runner" do
      ADK.LLM.Mock.set_responses(["mock response"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "pipeline_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "my_application", agent: agent)
      _events = Runner.run(runner, "user1", "cb-pipeline", "Hi", callbacks: [ContextCapture])

      cb_ctx = Process.get(:captured_cb_ctx)
      # app_name is set on the context by the runner
      assert cb_ctx.context.app_name == "my_application"
    end

    test "callback context has correct user_id" do
      ADK.LLM.Mock.set_responses(["mock response"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "user_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)
      _events = Runner.run(runner, "specific_user", "cb-user", "Hi", callbacks: [ContextCapture])

      cb_ctx = Process.get(:captured_cb_ctx)
      assert cb_ctx.context.user_id == "specific_user"
    end

    test "multiple callbacks run in order" do
      ADK.LLM.Mock.set_responses(["mock chain response"])

      agent =
        LlmAgent.new(
          model: "test-model",
          name: "chain_agent",
          instruction: "Help"
        )

      runner = Runner.new(app_name: "test_app", agent: agent)

      events =
        Runner.run(runner, "user1", "cb-chain", "Hi",
          callbacks: [ContextCapture, AfterAgentAppendCallback]
        )

      # ContextCapture's before_agent continues, LLM runs, then AfterAgentAppendCallback appends
      texts = Enum.map(events, &event_text/1)
      assert "appended by after_agent" in texts
      # ContextCapture should have captured the context
      assert Process.get(:captured_cb_ctx) != nil
    end
  end
end
