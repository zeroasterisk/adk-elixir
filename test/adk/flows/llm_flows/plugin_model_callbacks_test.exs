defmodule ADK.Flows.LlmFlows.PluginModelCallbacksParityTest do
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Event

  defmodule MockPlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def before_model(ctx, request) do
      plugin_state = get_plugin_state(ctx)

      if plugin_state[:enable_before_model_callback] do
        response =
          {:ok,
           %{
             content: %{role: :model, parts: [%{text: plugin_state[:before_model_text]}]}
           }}

        {:skip, response}
      else
        {:ok, request}
      end
    end

    @impl true
    def on_model_error(ctx, error) do
      plugin_state = get_plugin_state(ctx)

      if plugin_state[:enable_on_model_error_callback] do
        response = %{
          content: %{role: :model, parts: [%{text: plugin_state[:on_model_error_text]}]}
        }

        {:ok, response}
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

  defmodule MockCallback do
    @behaviour ADK.Callback
    def before_model(_ctx) do
      {:halt,
       {:ok, %{content: %{role: :model, parts: [%{text: "canonical_model_callback_content"}]}}}}
    end
  end

  setup do
    if Process.whereis(ADK.Plugin.Registry) do
      ADK.Plugin.Registry.clear()
    else
      {:ok, _} = ADK.Plugin.Registry.start_link()
    end

    on_exit(fn ->
      if Process.whereis(ADK.Plugin.Registry), do: ADK.Plugin.Registry.clear()
    end)

    :ok
  end

  test "before_model_callback_with_plugin: overrides model response" do
    ADK.LLM.Mock.set_responses([
      "model_response"
    ])

    plugin_config = [
      enable_before_model_callback: true,
      before_model_text: "before_model_text from MockPlugin"
    ]

    ADK.Plugin.Registry.register({MockPlugin, plugin_config})

    agent = %LlmAgent{
      name: "root_agent",
      model: "mock"
    }

    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")

    assert [event | _] = events
    assert Event.text(event) == "before_model_text from MockPlugin"
    assert event.author == "root_agent"
  end

  test "before_model_fallback_canonical_callback: falls back to canonical agent callback" do
    ADK.LLM.Mock.set_responses([
      "model_response"
    ])

    plugin_config = [
      enable_before_model_callback: false,
      before_model_text: "before_model_text from MockPlugin"
    ]

    ADK.Plugin.Registry.register({MockPlugin, plugin_config})

    agent = %LlmAgent{
      name: "root_agent",
      model: "mock"
    }

    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test", callbacks: [MockCallback])

    assert [event | _] = events
    assert Event.text(event) == "canonical_model_callback_content"
    assert event.author == "root_agent"
  end

  test "before_model_callback_fallback_model: executes normally when no callback/plugin returns response" do
    ADK.LLM.Mock.set_responses([
      "model_response"
    ])

    plugin_config = [
      enable_before_model_callback: false
    ]

    ADK.Plugin.Registry.register({MockPlugin, plugin_config})

    agent = %LlmAgent{
      name: "root_agent",
      model: "mock"
    }

    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")

    assert [event | _] = events
    assert Event.text(event) == "model_response"
    assert event.author == "root_agent"
  end

  test "on_model_error_callback_with_plugin: plugin handles model error" do
    mock_error = %RuntimeError{message: "Quota exceeded"}

    ADK.LLM.Mock.set_responses([
      {:error, mock_error}
    ])

    plugin_config = [
      enable_on_model_error_callback: true,
      on_model_error_text: "on_model_error_text from MockPlugin"
    ]

    ADK.Plugin.Registry.register({MockPlugin, plugin_config})

    agent = %LlmAgent{
      name: "root_agent",
      model: "mock"
    }

    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")

    assert [event | _] = events
    assert Event.text(event) == "on_model_error_text from MockPlugin"
    assert event.author == "root_agent"
  end

  test "on_model_error_callback_fallback_to_runner: error falls back to runner when plugin ignores it" do
    mock_error = %RuntimeError{message: "Quota exceeded"}

    ADK.LLM.Mock.set_responses([
      {:error, mock_error}
    ])

    plugin_config = [
      enable_on_model_error_callback: false
    ]

    ADK.Plugin.Registry.register({MockPlugin, plugin_config})

    agent = %LlmAgent{
      name: "root_agent",
      model: "mock"
    }

    runner = ADK.Runner.new(app_name: "test", agent: agent)
    events = ADK.Runner.run(runner, "u1", "sess1", "test")

    assert [event | _] = events
    assert event.error == mock_error
    assert Event.text(event) =~ "Error: %RuntimeError"
    assert event.author == "root_agent"
  end
end
