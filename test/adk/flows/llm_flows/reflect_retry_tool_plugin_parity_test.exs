defmodule ADK.Flows.LlmFlows.ReflectRetryToolPluginParityTest do
  use ExUnit.Case, async: false

  alias ADK.Plugin.ReflectRetry
  alias ADK.Agent.LlmAgent
  alias ADK.Event

  setup do
    if Process.whereis(ADK.Plugin.Registry) do
      ADK.Plugin.Registry.clear()
    else
      {:ok, _} = ADK.Plugin.Registry.start_link()
      on_exit(fn -> if Process.whereis(ADK.Plugin.Registry), do: Agent.stop(ADK.Plugin.Registry) end)
    end
    :ok
  end

  test "plugin_initialization_default" do
    {:ok, state} = ReflectRetry.init([])
    assert state.max_retries == 3
    assert state.validator == nil
    assert String.contains?(state.reflection_template, "{reason}")
  end

  test "plugin_initialization_custom" do
    {:ok, state} = ReflectRetry.init([max_retries: 5, validator: &(&1), reflection_template: "custom {reason}"])
    assert state.max_retries == 5
    assert is_function(state.validator)
    assert state.reflection_template == "custom {reason}"
  end

  test "after_run_successful_call: no retry if successful" do
    ADK.Plugin.Registry.register({ReflectRetry, []})
    ADK.LLM.Mock.set_responses(["Success response"])

    agent = %LlmAgent{name: "root_agent", model: "mock"}
    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")
    
    # We should get 1 event with the successful response
    assert length(events) == 1
    assert Event.text(Enum.at(events, 0)) == "Success response"
  end

  test "retry_behavior_with_first_failure: error event triggers retry" do
    ADK.Plugin.Registry.register({ReflectRetry, []})
    ADK.LLM.Mock.set_responses([
      %{error: "First failure"},
      "Success after retry"
    ])

    agent = %LlmAgent{name: "root_agent", model: "mock"}
    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")
    
    # Events should be: [First error event, reflection event, Success after retry event]
    assert length(events) == 3
    assert Enum.at(events, 0).error == "First failure"
    assert Enum.at(events, 1).author == "system"
    assert Event.text(Enum.at(events, 1)) =~ "Reflect & Retry"
    assert Event.text(Enum.at(events, 1)) =~ "First failure"
    assert Event.text(Enum.at(events, 2)) == "Success after retry"
  end

  test "retry_behavior_with_consecutive_failures: exhausts retries" do
    ADK.Plugin.Registry.register({ReflectRetry, [max_retries: 2]})
    ADK.LLM.Mock.set_responses([
      %{error: "Failure 1"},
      %{error: "Failure 2"},
      %{error: "Failure 3"},
      "Success (too late)"
    ])

    agent = %LlmAgent{name: "root_agent", model: "mock"}
    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")
    
    # Run:
    # 1. Error 1 -> retry 1
    # 2. Error 2 -> retry 2
    # 3. Error 3 -> exhausted
    assert length(events) == 5
    assert Enum.at(events, 0).error == "Failure 1"
    assert Enum.at(events, 1).author == "system" # reflection 1
    assert Enum.at(events, 2).error == "Failure 2"
    assert Enum.at(events, 3).author == "system" # reflection 2
    assert Enum.at(events, 4).error == "Failure 3"
  end

  test "custom_error_detection_and_success_handling: validator triggers retry" do
    validator = fn events ->
      text = Enum.map_join(events, " ", &Event.text/1)
      if String.contains?(text, "I don't know") do
        {:error, "Please provide a concrete answer"}
      else
        :ok
      end
    end
    
    ADK.Plugin.Registry.register({ReflectRetry, [validator: validator]})
    ADK.LLM.Mock.set_responses([
      "I don't know the answer.",
      "The answer is 42."
    ])

    agent = %LlmAgent{name: "root_agent", model: "mock"}
    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")
    
    assert length(events) == 3
    assert Event.text(Enum.at(events, 0)) == "I don't know the answer."
    assert Enum.at(events, 1).author == "system"
    assert Event.text(Enum.at(events, 1)) =~ "concrete answer"
    assert Event.text(Enum.at(events, 2)) == "The answer is 42."
  end

  test "hallucinating_tool_name: handled gracefully" do
    # Simulate a tool error which we can construct manually by creating a custom agent 
    # that uses a plugin or callback to return a custom error, but simpler is to 
    # just return an error from the mocked function tool.
    
    defmodule IncreaseTool do
      @behaviour ADK.Tool
      def name, do: "increase"
      def description, do: "Increase a number"
      def run(_ctx, %{"x" => x}), do: {:ok, x + 1}
      def declaration, do: %{name: name(), description: description(), parameters: %{}}
    end

    ADK.Plugin.Registry.register({ReflectRetry, []})
    
    ADK.LLM.Mock.set_responses([
      # First response: model tries to call hallucinated tool "increase_by_one"
      %{content: %{role: :model, parts: [%{function_call: %{name: "increase_by_one", args: %{"x" => 1}, id: "call-1"}}]}},
      # Second response: model calls correct tool
      %{content: %{role: :model, parts: [%{function_call: %{name: "increase", args: %{"x" => 1}, id: "call-2"}}]}},
      # Third response: final
      "Final answer: 2"
    ])

    agent = %LlmAgent{name: "root_agent", model: "mock", tools: [IncreaseTool]}
    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")
    
    # We should see:
    # 1. model asks for increase_by_one
    # 2. runner gives tool error event (error: Unknown tool: increase_by_one)
    # wait... ADK doesn't emit error events for tools, it wraps them in function_response!
    # Let's see how ADK LlmAgent handles tool errors.
  end
end
