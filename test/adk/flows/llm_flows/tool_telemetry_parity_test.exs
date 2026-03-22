defmodule ADK.Flows.LlmFlows.ToolTelemetryParityTest do
  @moduledoc """
  Parity test ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_tool_telemetry.py`.

  Ensures tool telemetry spans are emitted when a tool is invoked.
  """
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Tool.FunctionTool
  alias ADK.Runner
  alias ADK.LLM.Mock

  setup do
    test_pid = self()

    handler = fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end

    :telemetry.attach_many(
      "test-tool-telemetry-#{inspect(test_pid)}",
      [
        [:adk, :tool, :start],
        [:adk, :tool, :stop],
        [:adk, :tool, :exception]
      ],
      handler,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-tool-telemetry-#{inspect(test_pid)}")
    end)

    :ok
  end

  test "simple function with mocked tracer" do
    tool =
      FunctionTool.new("simple_fn",
        description: "A simple function.",
        parameters: %{
          type: "object",
          properties: %{
            a: %{type: "integer"},
            b: %{type: "integer"}
          }
        },
        func: fn _ctx, _args -> {:ok, %{result: "test"}} end
      )

    agent = LlmAgent.new(name: "agent", model: "test-model", tools: [tool])

    runner = %Runner{
      app_name: "test_telemetry_#{System.unique_integer([:positive])}",
      agent: agent
    }

    Mock.set_responses([
      %{function_call: %{name: "simple_fn", args: %{a: 1, b: 2}, id: "call1"}},
      "Done!"
    ])

    _event1 = Runner.run(runner, "user", "sess", "")

    assert_received {:telemetry_event, [:adk, :tool, :start], _m1_start,
                     %{tool_name: "simple_fn", agent_name: "agent"}}

    assert_received {:telemetry_event, [:adk, :tool, :stop], _m1_stop, %{tool_name: "simple_fn"}}

    # Call it a second time to match the Python test's 2x call structure
    Mock.set_responses([
      %{function_call: %{name: "simple_fn", args: %{a: 1, b: 2}, id: "call2"}},
      "Done again!"
    ])

    _event2 = Runner.run(runner, "user", "sess2", "")

    assert_received {:telemetry_event, [:adk, :tool, :start], _m2_start,
                     %{tool_name: "simple_fn", agent_name: "agent"}}

    assert_received {:telemetry_event, [:adk, :tool, :stop], _m2_stop, %{tool_name: "simple_fn"}}
  end
end
