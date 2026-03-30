defmodule ADK.Plugin.BigQueryAgentAnalyticsTest do
  use ExUnit.Case, async: false

  alias ADK.Plugin.BigQueryAgentAnalytics
  alias ADK.Context
  alias ADK.Event
  alias ADK.EventActions

  defmodule MockClient do
    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def insert(_state, record) do
      Agent.update(__MODULE__, fn records -> [record | records] end)
      :ok
    end

    def get_records do
      Agent.get(__MODULE__, & &1)
    end

    def clear do
      Agent.update(__MODULE__, fn _ -> [] end)
    end
  end

  setup do
    MockClient.start_link()
    MockClient.clear()

    # Reset Application env
    Application.delete_env(:adk, :bigquery_analytics_plugin_state)

    :ok
  end

  defp setup_plugin(opts \\ []) do
    defaults = [
      project_id: "test_project",
      dataset_id: "test_dataset",
      client: MockClient
    ]

    config = Keyword.merge(defaults, opts)
    {:ok, state} = BigQueryAgentAnalytics.init(config)
    state
  end

  defp create_context do
    %Context{
      invocation_id: "inv-123",
      session_pid: spawn(fn -> :ok end),
      app_name: "test-app",
      user_id: "user-1",
      agent: %{name: "TestAgent", model: "gemini-1.5-pro"}
    }
  end

  describe "Initialization" do
    test "init/1 sets state correctly" do
      state = setup_plugin()
      assert state.project_id == "test_project"
      assert state.dataset_id == "test_dataset"
      assert state.table_id == "adk_events"
    end
  end

  describe "Event callbacks" do
    test "before_run/2 logs INVOCATION_STARTING" do
      state = setup_plugin()
      ctx = create_context()

      {:cont, ^ctx, _} = BigQueryAgentAnalytics.before_run(ctx, state)

      [record] = MockClient.get_records()
      assert record.event_type == "INVOCATION_STARTING"
      assert record.invocation_id == "inv-123"
      assert record.session_id == inspect(ctx.session_pid)
      assert record.agent == "TestAgent"
    end

    test "after_run/3 logs INVOCATION_COMPLETED" do
      state = setup_plugin()
      ctx = create_context()

      {[:result], _} = BigQueryAgentAnalytics.after_run([:result], ctx, state)

      [record] = MockClient.get_records()
      assert record.event_type == "INVOCATION_COMPLETED"
    end

    test "before_model/2 logs LLM_REQUEST" do
      setup_plugin()
      ctx = create_context()
      request = %{contents: [%{role: "user", parts: [%{text: "Hello"}]}]}

      {:ok, ^request} = BigQueryAgentAnalytics.before_model(ctx, request)

      [record] = MockClient.get_records()
      assert record.event_type == "LLM_REQUEST"

      # Content should be JSON encoded
      assert record.content =~ "Hello"
      assert record.content =~ "gemini-1.5-pro"
    end

    test "after_model/2 logs LLM_RESPONSE" do
      setup_plugin()
      ctx = create_context()
      response = {:ok, %{candidates: [%{content: %{parts: [%{text: "Hi"}]}}]}}

      ^response = BigQueryAgentAnalytics.after_model(ctx, response)

      [record] = MockClient.get_records()
      assert record.event_type == "LLM_RESPONSE"
      assert record.status == "OK"
    end

    test "on_model_error/2 logs LLM_ERROR" do
      setup_plugin()
      ctx = create_context()
      error = {:error, "Model timeout"}

      ^error = BigQueryAgentAnalytics.on_model_error(ctx, error)

      [record] = MockClient.get_records()
      assert record.event_type == "LLM_ERROR"
      assert record.status == "ERROR"
    end

    test "before_tool/3 logs TOOL_STARTING" do
      setup_plugin()
      ctx = create_context()

      {:ok, %{arg1: "value1"}} =
        BigQueryAgentAnalytics.before_tool(ctx, "my_tool", %{arg1: "value1"})

      [record] = MockClient.get_records()
      assert record.event_type == "TOOL_STARTING"
      assert record.content =~ "my_tool"
      assert record.content =~ "value1"
    end

    test "after_tool/3 logs TOOL_COMPLETED" do
      setup_plugin()
      ctx = create_context()

      result = %{output: "success"}
      ^result = BigQueryAgentAnalytics.after_tool(ctx, "my_tool", result)

      [record] = MockClient.get_records()
      assert record.event_type == "TOOL_COMPLETED"
      assert record.content =~ "my_tool"
      assert record.content =~ "success"
    end

    test "on_tool_error/3 logs TOOL_ERROR" do
      setup_plugin()
      ctx = create_context()
      error = {:error, "Tool failed"}

      ^error = BigQueryAgentAnalytics.on_tool_error(ctx, "my_tool", error)

      [record] = MockClient.get_records()
      assert record.event_type == "TOOL_ERROR"
      assert record.status == "ERROR"
    end

    test "on_event/2 logs USER_MESSAGE_RECEIVED" do
      setup_plugin()
      ctx = create_context()
      event = %Event{type: :user_message, content: %{parts: [%{text: "User says hi"}]}}

      :ok = BigQueryAgentAnalytics.on_event(ctx, event)

      [record] = MockClient.get_records()
      assert record.event_type == "USER_MESSAGE_RECEIVED"
    end

    test "on_event/2 logs STATE_DELTA" do
      setup_plugin()
      ctx = create_context()
      event = %Event{type: :state_delta, actions: %EventActions{state_delta: %{key: "val"}}}

      :ok = BigQueryAgentAnalytics.on_event(ctx, event)

      [record] = MockClient.get_records()
      assert record.event_type == "STATE_DELTA"
    end
  end

  describe "Content handling" do
    test "truncates large content" do
      setup_plugin(max_content_length: 50)
      ctx = create_context()

      # 100 characters, exceeding the 50 limit
      large_arg = String.duplicate("A", 100)

      BigQueryAgentAnalytics.before_tool(ctx, "long_tool", %{arg: large_arg})

      [record] = MockClient.get_records()
      assert record.is_truncated == true
      assert record.content =~ "TRUNCATED"
      # Maximum length should be around the limit, plus the truncation notice length
      assert String.length(record.content) < 150
    end

    test "does not truncate short content" do
      setup_plugin(max_content_length: 500)
      ctx = create_context()

      short_arg = "Short string"

      BigQueryAgentAnalytics.before_tool(ctx, "short_tool", %{arg: short_arg})

      [record] = MockClient.get_records()
      assert record.is_truncated == false
      refute record.content =~ "TRUNCATED"
    end
  end

  describe "Attributes Enrichment" do
    test "includes session metadata by default" do
      state = setup_plugin()
      ctx = create_context()

      BigQueryAgentAnalytics.before_run(ctx, state)

      [record] = MockClient.get_records()
      attrs = Jason.decode!(record.attributes)

      assert attrs["session_metadata"]["session_id"] == inspect(ctx.session_pid)
      assert attrs["session_metadata"]["app_name"] == "test-app"
    end

    test "excludes session metadata if configured false" do
      state = setup_plugin(log_session_metadata: false)
      ctx = create_context()

      BigQueryAgentAnalytics.before_run(ctx, state)

      [record] = MockClient.get_records()
      attrs = Jason.decode!(record.attributes)

      refute Map.has_key?(attrs, "session_metadata")
    end

    test "includes custom tags" do
      state = setup_plugin(custom_tags: %{"env" => "test"})
      ctx = create_context()

      BigQueryAgentAnalytics.before_run(ctx, state)

      [record] = MockClient.get_records()
      attrs = Jason.decode!(record.attributes)

      assert attrs["custom_tags"]["env"] == "test"
    end
  end
end
