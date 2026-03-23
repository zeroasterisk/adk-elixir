defmodule ADK.Plugin.ReflectRetryToolParityTest do
  use ExUnit.Case, async: false

  alias ADK.Plugin.ReflectRetryTool

  @moduledoc """
  Parity tests for Python ADK's `test_reflect_retry_tool_plugin.py`.
  """

  setup do
    ctx = %ADK.Context{invocation_id: "test_inv"}

    # Helper to init and setup process dictionary
    setup_plugin = fn opts ->
      {:ok, state} = ReflectRetryTool.init(opts)
      ReflectRetryTool.before_run(ctx, state)
      state
    end

    on_exit(fn ->
      ReflectRetryTool.after_run([], ctx, %{})
      if Process.whereis(ADK.Plugin.Registry), do: ADK.Plugin.Registry.clear()
    end)

    %{ctx: ctx, setup_plugin: setup_plugin}
  end

  test "plugin initialization default", %{setup_plugin: setup_plugin} do
    state = setup_plugin.([])
    assert state.max_retries == 3
    assert state.throw_exception_if_retry_exceeded == true
  end

  test "plugin initialization custom", %{setup_plugin: setup_plugin} do
    state = setup_plugin.(max_retries: 10, throw_exception_if_retry_exceeded: false)
    assert state.max_retries == 10
    assert state.throw_exception_if_retry_exceeded == false
  end

  test "after_tool successful call", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.([])
    result = {:ok, %{"success" => true, "data" => "test_data"}}

    callback_result = ReflectRetryTool.after_tool(ctx, "mock_tool", result)

    # Should return original result
    assert callback_result == result
  end

  test "after_tool ignore retry response", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.([])
    retry_result = {:ok, %{"response_type" => "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"}}

    callback_result = ReflectRetryTool.after_tool(ctx, "mock_tool", retry_result)

    # Should return the retry_result unaltered
    assert callback_result == retry_result
  end

  test "on_tool_error max_retries_zero", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.(max_retries: 0)
    error = %RuntimeError{message: "Test error"}

    assert_raise RuntimeError, "Test error", fn ->
      ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
    end
  end

  test "on_tool_error first_failure", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.([])
    error = %RuntimeError{message: "Test error message"}

    {:ok, result} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})

    assert result["response_type"] == "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"
    assert result["error_type"] == "RuntimeError"
    assert result["error_details"] == "Test error message"
    assert result["retry_count"] == 1
    assert result["reflection_guidance"] =~ "mock_tool"
    assert result["reflection_guidance"] =~ "Test error message"
  end

  test "retry behavior with consecutive failures", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.([])
    error = %RuntimeError{message: "Runtime error"}

    {:ok, result1} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
    assert result1["retry_count"] == 1

    {:ok, result2} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
    assert result2["response_type"] == "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"
    assert result2["retry_count"] == 2
  end

  test "different tools behavior", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.([])
    error = %RuntimeError{message: "Test error"}

    {:ok, result1} = ReflectRetryTool.on_tool_error(ctx, "tool1", {:error, error})
    assert result1["retry_count"] == 1

    {:ok, result2} = ReflectRetryTool.on_tool_error(ctx, "tool2", {:error, error})
    assert result2["response_type"] == "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"
    assert result2["retry_count"] == 1
  end

  test "max_retries exceeded with exception", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.(max_retries: 1, throw_exception_if_retry_exceeded: true)
    error = %RuntimeError{message: "Connection failed"}

    # First call should succeed and return retry response
    {:ok, _} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})

    # Second call should exceed and raise
    assert_raise RuntimeError, "Connection failed", fn ->
      ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
    end
  end

  test "max_retries exceeded without exception", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.(max_retries: 2, throw_exception_if_retry_exceeded: false)
    error = %RuntimeError{message: "Timeout occurred"}

    ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
    ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})

    {:ok, result} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})

    assert result["response_type"] == "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"
    assert result["error_type"] == "RuntimeError"
    assert result["reflection_guidance"] =~ "the retry limit has been exceeded"
    assert result["reflection_guidance"] =~ "Do not attempt to use the `mock_tool` tool again"
  end

  test "successful call resets retry behavior", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.([])
    error = %RuntimeError{message: "Test error"}

    {:ok, result1} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
    assert result1["retry_count"] == 1

    ReflectRetryTool.after_tool(ctx, "mock_tool", {:ok, %{"success" => true}})

    {:ok, result2} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
    assert result2["retry_count"] == 1
  end

  test "none result handling", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.([])

    callback_result = ReflectRetryTool.after_tool(ctx, "mock_tool", {:ok, nil})
    assert callback_result == {:ok, nil}
  end

  test "retry count progression", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.(max_retries: 5)
    error = %RuntimeError{message: "Test error"}

    Enum.each(1..3, fn i ->
      {:ok, result} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
      assert result["retry_count"] == i
    end)
  end

  test "max_retries parameter behavior", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.(max_retries: 1, throw_exception_if_retry_exceeded: false)
    error = %RuntimeError{message: "Test error"}

    ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})

    {:ok, result} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, error})
    assert result["reflection_guidance"] =~ "the retry limit has been exceeded"
  end

  test "default extract_error returns nil equivalent", %{ctx: ctx, setup_plugin: setup_plugin} do
    setup_plugin.([])
    result = {:ok, %{"status" => "success", "data" => "some data"}}

    assert ReflectRetryTool.after_tool(ctx, "mock_tool", result) == result
  end

  test "custom error detection and success handling", %{ctx: ctx, setup_plugin: setup_plugin} do
    extract_error = fn _ctx, _tool_name, result ->
      if is_map(result) and result["status"] == "error", do: result["message"], else: nil
    end

    setup_plugin.(extract_error_from_result: extract_error)

    error_result = {:ok, %{"status" => "error", "message" => "Something went wrong"}}
    {:ok, callback_result} = ReflectRetryTool.after_tool(ctx, "mock_tool", error_result)

    assert callback_result["response_type"] == "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"
    assert callback_result["retry_count"] == 1

    success_result = {:ok, %{"status" => "success", "data" => "operation completed"}}
    assert ReflectRetryTool.after_tool(ctx, "mock_tool", success_result) == success_result
  end

  test "retry state management", %{ctx: ctx, setup_plugin: setup_plugin} do
    extract_error = fn _ctx, _tool_name, result ->
      if is_map(result) and result["failed"], do: result["reason"], else: nil
    end

    setup_plugin.(extract_error_from_result: extract_error)

    custom_error = {:ok, %{"failed" => true, "reason" => "Network timeout"}}
    {:ok, result1} = ReflectRetryTool.after_tool(ctx, "mock_tool", custom_error)
    assert result1["retry_count"] == 1

    exception = %RuntimeError{message: "Invalid parameter"}
    {:ok, result2} = ReflectRetryTool.on_tool_error(ctx, "mock_tool", {:error, exception})
    assert result2["retry_count"] == 2

    success = {:ok, %{"result" => "success"}}
    assert ReflectRetryTool.after_tool(ctx, "mock_tool", success) == success

    {:ok, result4} = ReflectRetryTool.after_tool(ctx, "mock_tool", custom_error)
    assert result4["retry_count"] == 1
  end

  test "hallucinating tool name integration" do
    # Testing this via Mock LLM and Runner.
    # In Python, they give responses: wrong tool call -> guidance -> correct tool call

    agent =
      ADK.Agent.LlmAgent.new(
        name: "root_agent",
        model: "test",
        tools: [
          ADK.Tool.FunctionTool.new(:increase,
            description: "increase",
            func: fn %{"x" => x} -> x + 1 end,
            parameters: %{
              "type" => "object",
              "properties" => %{"x" => %{"type" => "integer"}},
              "required" => ["x"]
            }
          )
        ]
      )

    ADK.LLM.Mock.set_responses([
      %{function_call: %{name: "increase_by_one", args: %{"x" => 1}}},
      %{function_call: %{name: "increase", args: %{"x" => 1}}},
      %{text: "response1"}
    ])

        case ADK.Plugin.Registry.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
    ADK.Plugin.Registry.clear()
    ADK.Plugin.Registry.register(ADK.Plugin.ReflectRetryTool)

    runner =
      ADK.Runner.new(app_name: "test", agent: agent, plugins: [ADK.Plugin.ReflectRetryTool])

    events = ADK.Runner.run(runner, "u1", "s1", "test")

    # First event should be the user message (from run/4)
    # Actually events is a list of ALL events.
    # We want to see if the retry plugin injected the guidance.

    tool_call_errs =
      Enum.filter(events, fn e ->
        e.content &&
          match?(
            %{
              parts: [
                %{
                  function_response: %{
                    response: %{"response_type" => "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"}
                  }
                }
              ]
            },
            e.content
          )
      end)

    assert length(tool_call_errs) == 1

    err_event = hd(tool_call_errs)
    resp = hd(err_event.content.parts).function_response.response

    assert resp["error_type"] == "ToolError"
    assert resp["retry_count"] == 1

    assert resp["reflection_guidance"] =~ "not found" or
             resp["reflection_guidance"] =~ "available tools"

    # We check if the final tool call 'increase' was made.
    tool_calls =
      Enum.filter(events, fn e ->
        e.content && match?(%{parts: [%{function_call: %{name: "increase"}}]}, e.content)
      end)

    assert length(tool_calls) == 1
  end
end
