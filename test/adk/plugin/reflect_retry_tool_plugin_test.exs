defmodule ADK.Plugin.ReflectRetryToolTest do
  use ExUnit.Case, async: false

  alias ADK.Plugin.ReflectRetryTool
  alias ADK.Agent.LlmAgent
  alias ADK.Runner
  alias ADK.Event
  alias ADK.Tool.FunctionTool

  @response_type "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"

  setup do
    context = %{invocation_id: "test_invoke_id_#{System.unique_integer([:positive])}"}

    # Ensure registry is started and clear
    if Process.whereis(ADK.Plugin.Registry) == nil do
      ADK.Plugin.Registry.start_link()
    end

    ADK.Plugin.Registry.clear()

    on_exit(fn ->
      if Process.whereis(ADK.Plugin.Registry), do: ADK.Plugin.Registry.clear()
    end)

    {:ok, context: context}
  end

  defp setup_plugin(opts, context) do
    {:ok, state} = ReflectRetryTool.init(opts)
    {:cont, _ctx, _state} = ReflectRetryTool.before_run(context, state)
    state
  end

  defp teardown_plugin(context, state) do
    {[], _state} = ReflectRetryTool.after_run([], context, state)
  end

  describe "initialization" do
    test "test_plugin_initialization_default" do
      {:ok, state} = ReflectRetryTool.init()
      assert state.max_retries == 3
      assert state.throw_exception_if_retry_exceeded == true
      assert state.extract_error_from_result == nil
    end

    test "test_plugin_initialization_custom" do
      {:ok, state} =
        ReflectRetryTool.init(
          max_retries: 10,
          throw_exception_if_retry_exceeded: false
        )

      assert state.max_retries == 10
      assert state.throw_exception_if_retry_exceeded == false
    end
  end

  describe "after_tool callback" do
    test "test_after_tool_callback_successful_call", %{context: context} do
      state = setup_plugin([], context)
      result = {:ok, %{"success" => true, "data" => "test_data"}}

      # Should return the result unmodified
      assert ^result = ReflectRetryTool.after_tool(context, "mock_tool", result)

      teardown_plugin(context, state)
    end

    test "test_after_tool_callback_ignore_retry_response", %{context: context} do
      state = setup_plugin([], context)
      retry_result = {:ok, %{"response_type" => @response_type}}

      assert ^retry_result = ReflectRetryTool.after_tool(context, "mock_tool", retry_result)

      teardown_plugin(context, state)
    end

    test "test_none_result_handling", %{context: context} do
      state = setup_plugin([], context)

      assert {:ok, nil} = ReflectRetryTool.after_tool(context, "mock_tool", {:ok, nil})

      teardown_plugin(context, state)
    end
  end

  describe "on_tool_error callback" do
    test "test_on_tool_error_callback_max_retries_zero", %{context: context} do
      state = setup_plugin([max_retries: 0], context)
      error = %ArgumentError{message: "Test error"}

      assert_raise ArgumentError, "Test error", fn ->
        ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      end

      teardown_plugin(context, state)
    end

    test "test_on_tool_error_callback_first_failure", %{context: context} do
      state = setup_plugin([], context)
      error = %ArgumentError{message: "Test error message"}

      {:ok, result} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})

      assert result["response_type"] == @response_type
      assert result["error_type"] == "ArgumentError"
      assert String.contains?(result["error_details"], "Test error message")
      assert result["retry_count"] == 1
      assert String.contains?(result["reflection_guidance"], "mock_tool")
      assert String.contains?(result["reflection_guidance"], "Test error message")

      teardown_plugin(context, state)
    end

    test "test_retry_behavior_with_consecutive_failures", %{context: context} do
      state = setup_plugin([], context)
      error = %RuntimeError{message: "Runtime error"}

      {:ok, result1} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      assert result1["retry_count"] == 1

      {:ok, result2} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      assert result2["response_type"] == @response_type
      assert result2["retry_count"] == 2

      teardown_plugin(context, state)
    end

    test "test_different_tools_behavior", %{context: context} do
      state = setup_plugin([], context)
      error = %ArgumentError{message: "Test error"}

      {:ok, result1} = ReflectRetryTool.on_tool_error(context, "tool1", {:error, error})
      assert result1["retry_count"] == 1

      {:ok, result2} = ReflectRetryTool.on_tool_error(context, "tool2", {:error, error})
      assert result2["response_type"] == @response_type
      assert result2["retry_count"] == 1

      teardown_plugin(context, state)
    end

    test "test_max_retries_exceeded_with_exception", %{context: context} do
      state = setup_plugin([max_retries: 1, throw_exception_if_retry_exceeded: true], context)
      error = RuntimeError.exception("Connection failed")

      {:ok, result} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      assert result["retry_count"] == 1

      assert_raise RuntimeError, "Connection failed", fn ->
        ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      end

      teardown_plugin(context, state)
    end

    test "test_max_retries_exceeded_without_exception", %{context: context} do
      state = setup_plugin([max_retries: 2, throw_exception_if_retry_exceeded: false], context)
      error = RuntimeError.exception("Timeout occurred")

      ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})

      {:ok, result} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      assert result["response_type"] == @response_type
      assert result["error_type"] == "RuntimeError"
      assert String.contains?(result["reflection_guidance"], "retry limit has been exceeded")
      assert String.contains?(result["reflection_guidance"], "Do not attempt to use the")

      teardown_plugin(context, state)
    end

    test "test_successful_call_resets_retry_behavior", %{context: context} do
      state = setup_plugin([], context)
      error = %ArgumentError{message: "Test error"}

      {:ok, result1} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      assert result1["retry_count"] == 1

      ReflectRetryTool.after_tool(context, "mock_tool", {:ok, %{"success" => true}})

      {:ok, result2} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      assert result2["retry_count"] == 1

      teardown_plugin(context, state)
    end

    test "test_empty_tool_args_handling", %{context: context} do
      state = setup_plugin([], context)
      error = %ArgumentError{message: "Test error"}

      {:ok, result} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      assert result["response_type"] == @response_type

      teardown_plugin(context, state)
    end

    test "test_retry_count_progression", %{context: context} do
      state = setup_plugin([max_retries: 5], context)
      error = %ArgumentError{message: "Test error"}

      for i <- 1..3 do
        {:ok, result} = ReflectRetryTool.on_tool_error(context, "single_tool", {:error, error})
        assert result["retry_count"] == i
      end

      teardown_plugin(context, state)
    end

    test "test_max_retries_parameter_behavior", %{context: context} do
      state = setup_plugin([max_retries: 1, throw_exception_if_retry_exceeded: false], context)
      error = %ArgumentError{message: "Test error"}

      ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})
      {:ok, result} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, error})

      assert String.contains?(result["reflection_guidance"], "retry limit has been exceeded")

      teardown_plugin(context, state)
    end
  end

  describe "custom error extraction" do
    test "test_default_extract_error_returns_none", %{context: context} do
      state = setup_plugin([], context)
      result = {:ok, %{"status" => "success", "data" => "some data"}}

      assert ^result = ReflectRetryTool.after_tool(context, "mock_tool", result)

      teardown_plugin(context, state)
    end

    test "test_custom_error_detection_and_success_handling", %{context: context} do
      extract_error = fn _ctx, _tool_name, unwrapped ->
        if Map.get(unwrapped, "status") == "error" do
          unwrapped
        else
          nil
        end
      end

      state = setup_plugin([extract_error_from_result: extract_error], context)

      error_result = {:ok, %{"status" => "error", "message" => "Something went wrong"}}
      {:ok, callback_result} = ReflectRetryTool.after_tool(context, "mock_tool", error_result)

      assert callback_result["response_type"] == @response_type
      assert callback_result["retry_count"] == 1

      success_result = {:ok, %{"status" => "success", "data" => "operation completed"}}
      assert ^success_result = ReflectRetryTool.after_tool(context, "mock_tool", success_result)

      teardown_plugin(context, state)
    end

    test "test_retry_state_management", %{context: context} do
      extract_error = fn _ctx, _tool_name, unwrapped ->
        if Map.get(unwrapped, "failed") do
          unwrapped
        else
          nil
        end
      end

      state = setup_plugin([extract_error_from_result: extract_error], context)

      custom_error = {:ok, %{"failed" => true, "reason" => "Network timeout"}}
      {:ok, result1} = ReflectRetryTool.after_tool(context, "mock_tool", custom_error)
      assert result1["retry_count"] == 1

      exception = %ArgumentError{message: "Invalid parameter"}
      {:ok, result2} = ReflectRetryTool.on_tool_error(context, "mock_tool", {:error, exception})
      assert result2["retry_count"] == 2

      success = {:ok, %{"result" => "success"}}
      assert ^success = ReflectRetryTool.after_tool(context, "mock_tool", success)

      {:ok, result4} = ReflectRetryTool.after_tool(context, "mock_tool", custom_error)
      assert result4["retry_count"] == 1

      teardown_plugin(context, state)
    end
  end

  describe "Runner integration" do
    test "test_hallucinating_tool_name" do
      increase_tool =
        FunctionTool.new(:increase,
          description: "Increase by one",
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}},
          func: fn _ctx, %{"x" => x} -> {:ok, x + 1} end
        )

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "increase_by_one", args: %{"x" => 1}}},
        %{function_call: %{name: "increase", args: %{"x" => 1}}},
        "response1"
      ])

      agent = LlmAgent.new(name: "root_agent", model: "mock", instruction: "test")

      # For Elixir ADK, tools must be available either globally or on the agent.
      agent = %{agent | tools: [increase_tool]}

      ADK.Plugin.Registry.register({ReflectRetryTool, []})

      runner = Runner.new(app_name: "test_runner", agent: agent)

      events = Runner.run(runner, "user1", "s_ref_#{System.unique_integer([:positive])}", "test")

      # We check the events sequence.

      # Wait, in ADK Elixir `function_response` and `function_call` parts define tool interactions
      # We just check events where `role` is `:user` (meaning tool result sent back to model).
      tool_responses = Enum.filter(events, &(&1.content[:role] == :user))

      assert length(tool_responses) >= 2

      # First response should be from increase_by_one with retry guidance
      retry_event =
        Enum.find(tool_responses, fn e ->
          Enum.any?(e.content[:parts], fn part ->
            part[:function_response][:name] == "increase_by_one"
          end)
        end)

      assert retry_event != nil

      response_part = hd(retry_event.content[:parts])
      response_data = response_part[:function_response][:response]

      assert response_data["response_type"] == @response_type
      assert response_data["retry_count"] == 1
      assert String.contains?(response_data["reflection_guidance"], "increase_by_one")

      # Second response should be success from increase tool
      success_event =
        Enum.find(tool_responses, fn e ->
          Enum.any?(e.content[:parts], fn part ->
            part[:function_response][:name] == "increase"
          end)
        end)

      assert success_event != nil

      success_part = hd(success_event.content[:parts])
      assert success_part[:function_response][:response] == %{"result" => 2}

      # Check model response texts
      model_events = Enum.filter(events, &(&1.content[:role] == :model))
      last_model_event = List.last(model_events)
      assert Event.text(last_model_event) == "response1"

      ADK.Plugin.Registry.clear()
    end
  end
end
