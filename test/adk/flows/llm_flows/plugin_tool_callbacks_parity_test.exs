defmodule ADK.Flows.LlmFlows.PluginToolCallbacksParityTest do
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent

  defmodule MockPlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def before_tool(ctx, _tool_name, _args) do
      plugin_state = get_plugin_state(ctx)

      if plugin_state[:enable_before_tool_callback] do
        {:skip, {:ok, %{mock_plugin: "before_tool_response from MockPlugin"}}}
      else
        {:ok, %{}}
      end
    end

    @impl true
    def after_tool(ctx, _tool_name, result) do
      plugin_state = get_plugin_state(ctx)

      if plugin_state[:enable_after_tool_callback] do
        {:ok, %{mock_plugin: "after_tool_response from MockPlugin"}}
      else
        result
      end
    end

    @impl true
    def on_tool_error(ctx, _tool_name, error) do
      plugin_state = get_plugin_state(ctx)

      if plugin_state[:enable_on_tool_error_callback] do
        {:ok, %{mock_plugin: "on_tool_error_response from MockPlugin"}}
      else
        error
      end
    end

    defp get_plugin_state(ctx) do
      Enum.find_value(ctx.plugins || [], %{}, fn {mod, st} ->
        if mod == __MODULE__, do: Map.new(st), else: nil
      end)
    end
  end

  defmodule MockToolCallbackBefore do
    @behaviour ADK.Callback
    def before_tool(_ctx) do
      {:halt, {:ok, %{agent: "should_not_be_called"}}}
    end
  end

  defmodule MockToolCallbackAfter do
    @behaviour ADK.Callback
    def after_tool(_result, _ctx) do
      {:ok, %{agent: "should_not_be_called"}}
    end
  end

  setup do
    if Process.whereis(ADK.Plugin.Registry) do
      ADK.Plugin.Registry.clear()
    else
      {:ok, _} = ADK.Plugin.Registry.start_link()
      on_exit(fn -> if Process.whereis(ADK.Plugin.Registry), do: Agent.stop(ADK.Plugin.Registry) end)
    end
    
    :ok
  end

  defp invoke_tool_with_plugin(plugin_config, tool_fun, callbacks \\ []) do
    ADK.Plugin.Registry.register({MockPlugin, plugin_config})

    mock_tool = ADK.Tool.FunctionTool.new(:mock_tool, func: tool_fun)

    agent = %LlmAgent{
      name: "agent",
      model: "mock",
      tools: [mock_tool]
    }

    ADK.LLM.Mock.set_responses([
      %{
        content: %{
          role: :model,
          parts: [
            %{
              function_call: %{
                name: "mock_tool",
                args: %{}
              }
            }
          ]
        }
      },
      %{
        content: %{
          role: :model,
          parts: [
            %{
              text: "done"
            }
          ]
        }
      }
    ])

    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test", callbacks: callbacks)
    
    events
  end

  test "before_tool_callback_with_plugin: overrides tool response" do
    plugin_config = [
      enable_before_tool_callback: true
    ]

    tool_fun = fn _, _ -> {:ok, %{initial: "response"}} end
    events = invoke_tool_with_plugin(plugin_config, tool_fun)

    assert [_call_event, result_event | _] = Enum.reverse(events)
    
    parts = result_event.content[:parts] || result_event.content.parts
    part = hd(parts)
    assert Map.get(part.function_response.response, :mock_plugin) == "before_tool_response from MockPlugin"
  end

  test "after_tool_callback_with_plugin: transforms tool response" do
    plugin_config = [
      enable_after_tool_callback: true
    ]

    tool_fun = fn _, _ -> {:ok, %{initial: "response"}} end
    events = invoke_tool_with_plugin(plugin_config, tool_fun)

    assert [_call_event, result_event | _] = Enum.reverse(events)
    
    parts = result_event.content[:parts] || result_event.content.parts
    part = hd(parts)
    assert Map.get(part.function_response.response, :mock_plugin) == "after_tool_response from MockPlugin"
  end

  test "on_tool_error_callback_with_plugin: plugin handles tool error" do
    plugin_config = [
      enable_on_tool_error_callback: true
    ]

    tool_fun = fn _, _ -> {:error, "Quota exceeded"} end
    events = invoke_tool_with_plugin(plugin_config, tool_fun)

    assert [_call_event, result_event | _] = Enum.reverse(events)
    
    parts = result_event.content[:parts] || result_event.content.parts
    part = hd(parts)
    assert Map.get(part.function_response.response, :mock_plugin) == "on_tool_error_response from MockPlugin"
  end

  test "on_tool_error_callback_fallback_to_runner: error falls back when plugin ignores it" do
    plugin_config = [
      enable_on_tool_error_callback: false
    ]

    tool_fun = fn _, _ -> {:error, "Quota exceeded"} end
    events = invoke_tool_with_plugin(plugin_config, tool_fun)

    assert [_call_event, result_event | _] = Enum.reverse(events)
    
    parts = result_event.content[:parts] || result_event.content.parts
    part = hd(parts)
    
    err = Map.get(part.function_response, :error) || inspect(part.function_response.response)
    assert String.contains?(err, "Quota")
  end

  test "plugin_before_tool_callback_takes_priority_over_agent" do
    plugin_config = [
      enable_before_tool_callback: true
    ]
    tool_fun = fn _, _ -> {:ok, %{initial: "response"}} end

    events = invoke_tool_with_plugin(plugin_config, tool_fun, [MockToolCallbackBefore])

    assert [_call_event, result_event | _] = Enum.reverse(events)
    
    parts = result_event.content[:parts] || result_event.content.parts
    part = hd(parts)
    assert Map.get(part.function_response.response, :mock_plugin) == "before_tool_response from MockPlugin"
  end

  test "plugin_after_tool_callback_takes_priority_over_agent" do
    plugin_config = [
      enable_after_tool_callback: true
    ]
    tool_fun = fn _, _ -> {:ok, %{initial: "response"}} end

    events = invoke_tool_with_plugin(plugin_config, tool_fun, [MockToolCallback])

    assert [_call_event, result_event | _] = Enum.reverse(events)
    
    parts = result_event.content[:parts] || result_event.content.parts
    part = hd(parts)
    assert Map.get(part.function_response.response, :mock_plugin) == "after_tool_response from MockPlugin"
  end
end
