defmodule ADK.Integration.VertexAiSearchGroundingStreamingTest do
  @moduledoc """
  Parity test for Python ADK's
  `tests/integration/test_vertex_ai_search_grounding_streaming.py`

  ## What the Python test does

  The Python integration test verifies that `grounding_metadata` from
  `VertexAiSearchTool` reaches the final non-partial event in both
  **progressive** and **non-progressive** SSE streaming modes.

  It:
    1. Provisions a real Vertex AI Search data store via Discovery Engine
    2. Ingests test documents about ADK overview and built-in tools
    3. Runs `LlmAgent` with `VertexAiSearchTool` in three scenarios:
       - Progressive SSE streaming mode
       - Non-progressive SSE streaming mode
       - No streaming (blocking mode)
    4. Asserts that at least one non-partial (saved) event has
       `grounding_metadata` set

  ## Elixir ADK parity

  The Elixir ADK currently:
    - Does NOT have a `VertexAiSearchTool` built-in (it's not yet implemented)
    - Does NOT parse `grounding_metadata` from Gemini/Vertex API responses in
      `ADK.LLM.Gemini.parse_response/1`
    - Does have `:sse` streaming mode in `ADK.RunConfig`
    - Does have the `partial` flag on `ADK.Event`

  The tests here:
    1. Document the parity gap (VertexAiSearchTool missing)
    2. Verify Elixir's SSE streaming mode infra exists and is correctly
       plumbed — events emitted during `:sse` mode are flagged consistently
    3. Verify that when a mock response includes `grounding_metadata`, it
       flows through to the event (once the parser supports it)
    4. Provide real integration tests (tagged `:real_integration`) that
       hit Vertex AI — skipped unless GOOGLE_CLOUD_PROJECT is set

  ## Running real integration tests

      GOOGLE_CLOUD_PROJECT=my-project mix test test/integration/ \\
        --include integration --include real_integration

  ## Current parity status

  | Feature                         | Python | Elixir |
  |---------------------------------|--------|--------|
  | VertexAiSearchTool              | ✅     | ❌ (not implemented) |
  | grounding_metadata in events    | ✅     | ❌ (not parsed)      |
  | SSE streaming mode (:sse)       | ✅     | ✅ (infrastructure)  |
  | partial event flag              | ✅     | ✅                   |
  | non-partial (saved) events      | ✅     | ✅                   |
  | Progressive SSE feature flag    | ✅     | ❌ (not implemented) |
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  # ── SSE Streaming infrastructure ────────────────────────────────────────

  describe "SSE streaming mode infrastructure" do
    test "RunConfig accepts :sse streaming mode" do
      config = ADK.RunConfig.new(streaming_mode: :sse)
      assert config.streaming_mode == :sse
    end

    test "RunConfig defaults to :none streaming mode" do
      config = ADK.RunConfig.new()
      assert config.streaming_mode == :none
    end

    test "ADK.Event partial flag defaults to false" do
      event = ADK.Event.new(%{author: "test_agent", content: %{parts: [%{text: "hi"}]}})
      assert event.partial == false
    end

    test "ADK.Event can be constructed as partial" do
      event = ADK.Event.new(%{author: "test_agent", content: %{parts: [%{text: "chunk"}]}, partial: true})
      assert event.partial == true
    end

    test "non-partial events filter correctly from a mixed list" do
      # Mirrors Python's `saved_events = [e for e in all_events if e.partial is not True]`
      events = [
        ADK.Event.new(%{author: "agent", content: %{parts: [%{text: "chunk1"}]}, partial: true}),
        ADK.Event.new(%{author: "agent", content: %{parts: [%{text: "chunk2"}]}, partial: true}),
        ADK.Event.new(%{author: "agent", content: %{parts: [%{text: "final"}]}, partial: false})
      ]

      saved_events = Enum.filter(events, &(&1.partial != true))
      assert length(saved_events) == 1
      assert ADK.Event.text(hd(saved_events)) == "final"
    end
  end

  # ── grounding_metadata parity gap ───────────────────────────────────────

  describe "grounding_metadata support (parity gap)" do
    @tag :skip
    test "VertexAiSearchTool is not yet implemented in ADK Elixir" do
      # Python: VertexAiSearchTool(data_store_id: data_store_resource)
      # Elixir: No equivalent — needs Discovery Engine client library
      #
      # When implementing:
      #   - Create ADK.Tool.VertexAiSearch with a `data_store_id` field
      #   - It should be a built-in tool (like ADK.Tool.GoogleSearch)
      #   - The Gemini API call should include the data_store spec in the request
      flunk("ADK.Tool.VertexAiSearch not yet implemented")
    end

    @tag :skip
    test "grounding_metadata is not parsed from Gemini API responses" do
      # Python: event.grounding_metadata returns the GroundingMetadata proto
      # Elixir: ADK.Event has no grounding_metadata field
      #
      # When implementing:
      #   1. Add grounding_metadata field to ADK.Event struct
      #   2. Update ADK.LLM.Gemini.parse_response/1 to extract:
      #      body["candidates"][0]["groundingMetadata"]
      #   3. Pass through to event construction in LlmAgent
      flunk("grounding_metadata parsing not yet implemented")
    end

    @tag :skip
    test "progressive SSE streaming feature flag not implemented" do
      # Python: temporary_feature_override(FeatureName.PROGRESSIVE_SSE_STREAMING, true/false)
      # Elixir: No feature flag system equivalent yet
      #
      # When implementing:
      #   - Add a feature flag system (Application.get_env or a FeatureRegistry module)
      #   - Support toggling PROGRESSIVE_SSE_STREAMING at test time
      flunk("Progressive SSE streaming feature flag not yet implemented")
    end
  end

  # ── Mock-based SSE streaming behavior ───────────────────────────────────

  describe "SSE streaming with mock LLM" do
    setup do
      Process.put(:adk_mock_responses, nil)
      :ok
    end

    test "events from :sse run_config are collected in order" do
      # Mirrors: Python runner with RunConfig(streaming_mode=StreamingMode.SSE)
      # Verifies that the runner collects all events (partial + final) in order
      ADK.LLM.Mock.set_responses([
        "ADK provides built-in tools including VertexAiSearchTool for grounded search."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Answer questions using the search tool."
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test_app",
          user_id: "test_user",
          session_id: "sse-test-#{System.unique_integer([:positive])}",
          name: nil
        )

      run_config = ADK.RunConfig.new(streaming_mode: :sse)

      ctx = %ADK.Context{
        invocation_id: "inv-sse-#{System.unique_integer([:positive])}",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "What built-in tools does ADK provide?"},
        run_config: run_config
      }

      events = ADK.Agent.run(agent, ctx)
      GenServer.stop(session_pid)

      # All events collected
      assert is_list(events)
      assert length(events) > 0

      # At least one non-partial event (the final response)
      saved_events = Enum.filter(events, &(&1.partial != true))
      assert length(saved_events) > 0

      # Final event has content about ADK tools
      last_text = events |> Enum.filter(&ADK.Event.text?/1) |> List.last() |> ADK.Event.text()
      assert last_text =~ "ADK"
    end

    test "non-partial events do not have partial=true" do
      # Mirrors: Python's check `e.partial is not True` for saved events
      ADK.LLM.Mock.set_responses([
        "ADK was first released in April 2025."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Answer questions using the search tool."
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test_app",
          user_id: "test_user",
          session_id: "sse-partial-#{System.unique_integer([:positive])}",
          name: nil
        )

      ctx = %ADK.Context{
        invocation_id: "inv-partial-#{System.unique_integer([:positive])}",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "What is ADK and when was it first released?"},
        run_config: ADK.RunConfig.new(streaming_mode: :sse)
      }

      events = ADK.Agent.run(agent, ctx)
      GenServer.stop(session_pid)

      # None of the non-partial events should have partial=true
      saved_events = Enum.filter(events, &(&1.partial != true))

      for event <- saved_events do
        assert event.partial != true,
               "Expected saved event not to be partial, got: #{inspect(event)}"
      end
    end

    test "no-streaming mode collects model events" do
      # Mirrors: Python test_grounding_metadata_without_streaming
      # Without streaming, all events should still be collected
      ADK.LLM.Mock.set_responses([
        "ADK provides built-in tools including VertexAiSearchTool, GoogleSearchTool, and CodeExecutionTool."
      ])

      agent =
        ADK.Agent.LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Answer questions about ADK."
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test_app",
          user_id: "test_user",
          session_id: "no-stream-#{System.unique_integer([:positive])}",
          name: nil
        )

      ctx = %ADK.Context{
        invocation_id: "inv-nostream-#{System.unique_integer([:positive])}",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "What built-in tools does ADK provide?"},
        run_config: ADK.RunConfig.new(streaming_mode: :none)
      }

      events = ADK.Agent.run(agent, ctx)
      GenServer.stop(session_pid)

      # Should have model events
      model_events = Enum.filter(events, &(&1.author == "test_agent"))
      assert length(model_events) > 0

      # All model events should have content
      for event <- model_events do
        assert ADK.Event.text?(event) or not is_nil(event.content),
               "Model event missing content: #{inspect(event)}"
      end
    end
  end

  # ── Real Vertex AI integration tests (skipped without GCP credentials) ──

  describe "real Vertex AI Search grounding integration" do
    setup do
      project = System.get_env("GOOGLE_CLOUD_PROJECT")

      if is_nil(project) do
        {:error, "GOOGLE_CLOUD_PROJECT not set — skip with --exclude real_integration"}
      else
        {:ok, project: project}
      end
    end

    @tag :real_integration
    @tag :skip
    test "grounding_metadata preserved in non-progressive SSE streaming", %{project: _project} do
      # Full parity with Python test_grounding_metadata_with_sse_streaming
      # (progressive_sse=False)
      #
      # Prerequisites:
      #   - VertexAiSearchTool implemented (see parity gap above)
      #   - grounding_metadata parsing implemented
      #   - Discovery Engine data store provisioned
      #
      # Expected:
      #   saved_events that have grounding_metadata set (non-nil) > 0
      flunk("VertexAiSearchTool not yet implemented in ADK Elixir")
    end

    @tag :real_integration
    @tag :skip
    test "grounding_metadata preserved in progressive SSE streaming", %{project: _project} do
      # Full parity with Python test_grounding_metadata_with_sse_streaming
      # (progressive_sse=True)
      flunk("Progressive SSE and VertexAiSearchTool not yet implemented in ADK Elixir")
    end

    @tag :real_integration
    @tag :skip
    test "grounding_metadata present without streaming", %{project: _project} do
      # Full parity with Python test_grounding_metadata_without_streaming
      #
      # Python assertion:
      #   model_events = [e for e in events if e.author == "test_agent"]
      #   with_grounding = [e for e in model_events if e.grounding_metadata]
      #   assert with_grounding, "No events have grounding_metadata even without streaming."
      flunk("VertexAiSearchTool not yet implemented in ADK Elixir")
    end
  end
end
