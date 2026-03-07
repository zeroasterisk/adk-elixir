defmodule ADK.TelemetryTest do
  use ExUnit.Case, async: true

  setup do
    test_pid = self()

    handler = fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end

    :telemetry.attach_many(
      "test-#{inspect(test_pid)}",
      ADK.Telemetry.events(),
      handler,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-#{inspect(test_pid)}")
    end)

    :ok
  end

  describe "ADK.Telemetry.span/3" do
    test "emits start and stop events" do
      result = ADK.Telemetry.span([:adk, :agent], %{agent_name: "test"}, fn -> :hello end)

      assert result == :hello

      assert_received {:telemetry_event, [:adk, :agent, :start], start_m, %{agent_name: "test"}}
      assert is_integer(start_m.monotonic_time)
      assert is_integer(start_m.system_time)

      assert_received {:telemetry_event, [:adk, :agent, :stop], stop_m, %{agent_name: "test"}}
      assert is_integer(stop_m.duration)
    end

    test "emits exception event on raise" do
      assert_raise RuntimeError, fn ->
        ADK.Telemetry.span([:adk, :llm], %{model: "test"}, fn -> raise "boom" end)
      end

      assert_received {:telemetry_event, [:adk, :llm, :start], _, %{model: "test"}}
      assert_received {:telemetry_event, [:adk, :llm, :exception], m, meta}
      assert is_integer(m.duration)
      assert meta.kind == :error
    end
  end

  describe "events/0" do
    test "returns all 9 events" do
      assert length(ADK.Telemetry.events()) == 9
    end
  end

  describe "agent telemetry via Runner" do
    test "emits agent start/stop events" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %ADK.Runner{app_name: "telemetry_test_#{System.unique_integer([:positive])}", agent: agent}

      ADK.Runner.run(runner, "user1", "sess1", "hi")

      assert_received {:telemetry_event, [:adk, :agent, :start], _, %{agent_name: "bot"}}
      assert_received {:telemetry_event, [:adk, :agent, :stop], %{duration: d}, %{agent_name: "bot"}}
      assert is_integer(d)
    end
  end

  describe "LLM telemetry" do
    test "emits llm start/stop events" do
      ADK.LLM.generate("test-model", %{messages: []})

      assert_received {:telemetry_event, [:adk, :llm, :start], _, %{model: "test-model"}}
      assert_received {:telemetry_event, [:adk, :llm, :stop], _, %{model: "test-model"}}
    end
  end

  describe "tool telemetry" do
    test "emits tool start/stop events when agent uses tools" do
      tool = ADK.Tool.FunctionTool.new("greet",
        description: "Say hello",
        parameters: %{},
        func: fn _ctx, _args -> {:ok, "hi there"} end
      )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "greet", args: %{}, id: "c1"}},
        "Done!"
      ])

      agent = ADK.Agent.LlmAgent.new(name: "toolbot", model: "test", instruction: "Use tools", tools: [tool])
      runner = %ADK.Runner{app_name: "telemetry_tool_#{System.unique_integer([:positive])}", agent: agent}

      ADK.Runner.run(runner, "user1", "sess1", "hi")

      assert_received {:telemetry_event, [:adk, :tool, :start], _, %{tool_name: "greet", agent_name: "toolbot"}}
      assert_received {:telemetry_event, [:adk, :tool, :stop], %{duration: _}, %{tool_name: "greet"}}
    end
  end
end
