defmodule ADK.CallbackTest do
  use ExUnit.Case, async: true

  alias ADK.{Runner, Callback, Event}

  defmodule LoggingCallback do
    @behaviour ADK.Callback

    @impl true
    def before_agent(cb_ctx) do
      send(self(), {:before_agent, cb_ctx.agent.name})
      {:cont, cb_ctx}
    end

    @impl true
    def after_agent(events, cb_ctx) do
      send(self(), {:after_agent, cb_ctx.agent.name, length(events)})
      events
    end

    @impl true
    def before_model(cb_ctx) do
      send(self(), {:before_model, cb_ctx.request.model})
      {:cont, cb_ctx}
    end

    @impl true
    def after_model(result, _cb_ctx) do
      send(self(), {:after_model, result})
      result
    end

    @impl true
    def before_tool(cb_ctx) do
      send(self(), {:before_tool, cb_ctx.tool.name})
      {:cont, cb_ctx}
    end

    @impl true
    def after_tool(result, _cb_ctx) do
      send(self(), {:after_tool, result})
      result
    end
  end

  defmodule HaltAgentCallback do
    @behaviour ADK.Callback

    @impl true
    def before_agent(_cb_ctx) do
      event = Event.new(%{invocation_id: "halted", author: "halt-cb", content: %{parts: [%{text: "halted!"}]}})
      {:halt, [event]}
    end
  end

  defmodule HaltModelCallback do
    @behaviour ADK.Callback

    @impl true
    def before_model(_cb_ctx) do
      response = %{content: %{role: :model, parts: [%{text: "intercepted"}]}, usage_metadata: nil}
      {:halt, {:ok, response}}
    end
  end

  defmodule TransformAfterAgent do
    @behaviour ADK.Callback

    @impl true
    def after_agent(events, _cb_ctx) do
      extra = Event.new(%{invocation_id: "extra", author: "transform-cb", content: %{parts: [%{text: "extra"}]}})
      events ++ [extra]
    end
  end

  defmodule NoopCallback do
    @behaviour ADK.Callback
    # Implements no optional callbacks — should be safely skipped
  end

  setup do
    # SessionSupervisor is started by the application
    :ok
  end

  describe "run_before/3 and run_after/4" do
    test "run_before with no callbacks returns cont" do
      assert {:cont, %{}} = Callback.run_before([], :before_agent, %{})
    end

    test "run_before halts on first halting callback" do
      assert {:halt, [_]} = Callback.run_before([HaltAgentCallback], :before_agent, %{agent: %{name: "x"}, context: %{}})
    end

    test "run_after with no callbacks returns result unchanged" do
      assert [1, 2] = Callback.run_after([], :after_agent, [1, 2], %{})
    end

    test "skips callbacks that don't implement the hook" do
      assert {:cont, %{}} = Callback.run_before([NoopCallback], :before_agent, %{})
      assert :result = Callback.run_after([NoopCallback], :after_agent, :result, %{})
    end
  end

  describe "agent callbacks via Runner" do
    test "before_agent and after_agent are called" do
      ADK.LLM.Mock.set_responses(["hello"])
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %Runner{app_name: "cb-test", agent: agent}

      events = Runner.run(runner, "u1", "s1", "hi", callbacks: [LoggingCallback])

      assert_received {:before_agent, "bot"}
      assert_received {:after_agent, "bot", _count}
      assert length(events) > 0
    end

    test "before_agent halt short-circuits execution" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %Runner{app_name: "cb-halt", agent: agent}

      events = Runner.run(runner, "u1", "s2", "hi", callbacks: [HaltAgentCallback])

      assert [%{author: "halt-cb"}] = events
    end

    test "after_agent can transform events" do
      ADK.LLM.Mock.set_responses(["ok"])
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %Runner{app_name: "cb-transform", agent: agent}

      events = Runner.run(runner, "u1", "s3", "hi", callbacks: [TransformAfterAgent])

      assert List.last(events).author == "transform-cb"
    end
  end

  describe "model callbacks" do
    test "before_model halt returns intercepted response" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %Runner{app_name: "cb-model", agent: agent}

      events = Runner.run(runner, "u1", "s4", "hi", callbacks: [HaltModelCallback])

      assert [event] = events
      assert ADK.Event.text(event) == "intercepted"
    end

    test "before_model and after_model are called on normal flow" do
      ADK.LLM.Mock.set_responses(["normal"])
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %Runner{app_name: "cb-model2", agent: agent}

      Runner.run(runner, "u1", "s5", "hi", callbacks: [LoggingCallback])

      assert_received {:before_model, "test"}
      assert_received {:after_model, {:ok, _}}
    end
  end

  describe "multiple callbacks" do
    test "callbacks run in order" do
      ADK.LLM.Mock.set_responses(["hi"])
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %Runner{app_name: "cb-multi", agent: agent}

      events = Runner.run(runner, "u1", "s6", "hi", callbacks: [NoopCallback, LoggingCallback, TransformAfterAgent])

      assert_received {:before_agent, "bot"}
      assert List.last(events).author == "transform-cb"
    end
  end
end
