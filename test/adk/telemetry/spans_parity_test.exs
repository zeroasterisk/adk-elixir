defmodule ADK.Telemetry.SpansParityTest do
  use ExUnit.Case, async: false

  alias ADK.Telemetry.Contract
  alias ADK.Agent.LlmAgent

  setup do
    test_pid = self()

    # We can attach telemetry handlers to verify telemetry payload parity with OpenTelemetry attributes
    handler = fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end

    :telemetry.attach_many(
      "test-spans-#{inspect(test_pid)}",
      [
        [:adk, :agent, :start],
        [:adk, :agent, :stop],
        [:adk, :llm, :start],
        [:adk, :llm, :stop],
        [:adk, :tool, :start],
        [:adk, :tool, :stop]
      ],
      handler,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-spans-#{inspect(test_pid)}")
    end)

    :ok
  end

  test "trace_agent_invocation sets span attributes correctly" do
    agent =
      LlmAgent.new(
        name: "test_llm_agent",
        model: "gemini-pro",
        description: "Test agent description"
      )

    meta = %{
      "gen_ai.operation.name" => "invoke_agent",
      "gen_ai.agent.description" => agent.description,
      "gen_ai.agent.name" => agent.name,
      "gen_ai.conversation.id" => "sess_123"
    }

    ADK.Telemetry.span([:adk, :agent], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :agent, :start], _m, recorded_meta}

    assert recorded_meta["gen_ai.operation.name"] == "invoke_agent"
    assert recorded_meta["gen_ai.agent.description"] == "Test agent description"
    assert recorded_meta["gen_ai.agent.name"] == "test_llm_agent"
    assert recorded_meta["gen_ai.conversation.id"] == "sess_123"
  end

  test "trace_call_llm sets all telemetry attributes correctly with normal content" do
    meta = %{
      "gen_ai.system" => "gcp.vertex.agent",
      "gen_ai.request.top_p" => 0.95,
      "gen_ai.request.max_tokens" => 1024,
      "gen_ai.usage.input_tokens" => 50,
      "gen_ai.usage.output_tokens" => 50,
      "gen_ai.usage.experimental.reasoning_tokens_limit" => 10,
      "gen_ai.usage.experimental.reasoning_tokens" => 10,
      "gen_ai.response.finish_reasons" => ["stop"]
    }

    ADK.Telemetry.span([:adk, :llm], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :llm, :start], _m, recorded_meta}

    assert recorded_meta["gen_ai.system"] == "gcp.vertex.agent"
    assert recorded_meta["gen_ai.request.top_p"] == 0.95
    assert recorded_meta["gen_ai.request.max_tokens"] == 1024
    assert recorded_meta["gen_ai.usage.input_tokens"] == 50
    assert recorded_meta["gen_ai.usage.output_tokens"] == 50
    assert recorded_meta["gen_ai.usage.experimental.reasoning_tokens_limit"] == 10
    assert recorded_meta["gen_ai.usage.experimental.reasoning_tokens"] == 10
    assert recorded_meta["gen_ai.response.finish_reasons"] == ["stop"]
  end

  test "trace_tool_call_with_scalar_response" do
    args = %{"param_a" => "value_a", "param_b" => 100}
    response = %{"result" => "Scalar result"}

    meta = %{
      "gen_ai.operation.name" => "execute_tool",
      "gen_ai.tool.name" => "sample_tool",
      "gen_ai.tool.description" => "A sample tool for testing.",
      "gen_ai.tool.type" => "BaseTool",
      "gen_ai.tool.call.id" => "tool_call_id_001",
      "gcp.vertex.agent.tool_call_args" => Jason.encode!(args),
      "gcp.vertex.agent.tool_response" => Jason.encode!(response)
    }

    ADK.Telemetry.span([:adk, :tool], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :tool, :start], _m, recorded_meta}

    assert recorded_meta["gen_ai.operation.name"] == "execute_tool"
    assert recorded_meta["gen_ai.tool.name"] == "sample_tool"
    assert recorded_meta["gen_ai.tool.description"] == "A sample tool for testing."
    assert recorded_meta["gen_ai.tool.call.id"] == "tool_call_id_001"

    assert recorded_meta["gcp.vertex.agent.tool_call_args"] ==
             "{\"param_a\":\"value_a\",\"param_b\":100}"

    assert recorded_meta["gcp.vertex.agent.tool_response"] == "{\"result\":\"Scalar result\"}"
  end

  test "trace_tool_call_with_dict_response" do
    args = %{"query" => "details", "id_list" => [1, 2, 3]}
    response = %{"data" => "structured_data", "count" => 5}

    meta = %{
      "gen_ai.operation.name" => "execute_tool",
      "gen_ai.tool.name" => "sample_tool",
      "gen_ai.tool.description" => "A sample tool for testing.",
      "gen_ai.tool.type" => "BaseTool",
      "gen_ai.tool.call.id" => "tool_call_id_002",
      "gcp.vertex.agent.tool_call_args" => Jason.encode!(args),
      "gcp.vertex.agent.tool_response" => Jason.encode!(response)
    }

    ADK.Telemetry.span([:adk, :tool], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :tool, :start], _m, recorded_meta}

    assert recorded_meta["gen_ai.operation.name"] == "execute_tool"
    assert recorded_meta["gen_ai.tool.name"] == "sample_tool"
    assert recorded_meta["gen_ai.tool.description"] == "A sample tool for testing."
    assert recorded_meta["gen_ai.tool.call.id"] == "tool_call_id_002"

    assert recorded_meta["gcp.vertex.agent.tool_call_args"] ==
             "{\"id_list\":[1,2,3],\"query\":\"details\"}"

    assert recorded_meta["gcp.vertex.agent.tool_response"] ==
             "{\"count\":5,\"data\":\"structured_data\"}"
  end

  test "trace_merged_tool_calls_sets_correct_attributes" do
    custom_event_json_output = "{\"custom_event_payload\": true, \"details\": \"merged_details\"}"

    meta = %{
      "gen_ai.operation.name" => "execute_tool",
      "gen_ai.tool.name" => "(merged tools)",
      "gen_ai.tool.description" => "(merged tools)",
      "gen_ai.tool.call.id" => "merged_evt_id_001",
      "gcp.vertex.agent.tool_call_args" => "N/A",
      "gcp.vertex.agent.event_id" => "merged_evt_id_001",
      "gcp.vertex.agent.tool_response" => custom_event_json_output
    }

    ADK.Telemetry.span([:adk, :tool], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :tool, :start], _m, recorded_meta}

    assert recorded_meta["gen_ai.tool.name"] == "(merged tools)"
    assert recorded_meta["gcp.vertex.agent.tool_call_args"] == "N/A"
    assert recorded_meta["gcp.vertex.agent.tool_response"] == custom_event_json_output
  end

  test "trace_tool_call_with_tool_execution_error" do
    args = %{"param_a" => "value_a"}

    meta = %{
      "gen_ai.operation.name" => "execute_tool",
      "gen_ai.tool.name" => "sample_tool",
      "gen_ai.tool.description" => "A sample tool for testing.",
      "error.type" => "INTERNAL_SERVER_ERROR",
      "gcp.vertex.agent.tool_call_args" => Jason.encode!(args),
      "gcp.vertex.agent.tool_response" => "{\"result\": \"<not specified>\"}",
      "gen_ai.tool.call.id" => "<not specified>"
    }

    ADK.Telemetry.span([:adk, :tool], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :tool, :start], _m, recorded_meta}

    assert recorded_meta["gen_ai.operation.name"] == "execute_tool"
    assert recorded_meta["gen_ai.tool.name"] == "sample_tool"
    assert recorded_meta["error.type"] == "INTERNAL_SERVER_ERROR"
    assert recorded_meta["gcp.vertex.agent.tool_call_args"] == "{\"param_a\":\"value_a\"}"
    assert recorded_meta["gcp.vertex.agent.tool_response"] == "{\"result\": \"<not specified>\"}"
  end

  test "trace_tool_call_with_standard_error" do
    meta = %{
      "error.type" => "ValueError"
    }

    ADK.Telemetry.span([:adk, :tool], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :tool, :start], _m, recorded_meta}
    assert recorded_meta["error.type"] == "ValueError"
  end

  test "trace_tool_call_with_timeout_error" do
    meta = %{
      "error.type" => "REQUEST_TIMEOUT"
    }

    ADK.Telemetry.span([:adk, :tool], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :tool, :start], _m, recorded_meta}
    assert recorded_meta["error.type"] == "REQUEST_TIMEOUT"
  end

  test "call_llm_disabling_request_response_content" do
    meta = %{
      "gcp.vertex.agent.llm_request" => "{}",
      "gcp.vertex.agent.llm_response" => "{}"
    }

    ADK.Telemetry.span([:adk, :llm], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :llm, :start], _m, recorded_meta}
    assert recorded_meta["gcp.vertex.agent.llm_request"] == "{}"
    assert recorded_meta["gcp.vertex.agent.llm_response"] == "{}"
  end

  test "trace_tool_call_disabling_request_response_content" do
    meta = %{
      "gcp.vertex.agent.tool_call_args" => "{}",
      "gcp.vertex.agent.tool_response" => "{}"
    }

    ADK.Telemetry.span([:adk, :tool], meta, fn -> :ok end)

    assert_received {:telemetry_event, [:adk, :tool, :start], _m, recorded_meta}
    assert recorded_meta["gcp.vertex.agent.tool_call_args"] == "{}"
    assert recorded_meta["gcp.vertex.agent.tool_response"] == "{}"
  end
end
