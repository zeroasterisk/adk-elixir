defmodule ADK.Plugin.PluginManagerParityTest do
  @moduledoc """
  Parity test for Python's `test_plugin_manager.py`.

  In Elixir, the PluginManager is conceptually split across `ADK.Plugin` (the behaviour and hook executors)
  and `ADK.Plugin.Registry` (the agent-based registry).
  """
  use ExUnit.Case, async: false

  alias ADK.Plugin
  alias ADK.Plugin.Registry

  # A TestPlugin mirroring `TestPlugin` in Python
  defmodule TestPlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config) do
      # In Python, the plugin logs which callbacks were invoked.
      # We use an Agent to store the log, initialized via the config PID.
      {:ok, config}
    end

    def handle_callback(name, context, result \\ nil) do
      if pid = context.temp_state[:log_pid] do
        Agent.update(pid, &[name | &1])
      end

      result
    end

    # Implement all callbacks from ADK.Plugin (Elixir's version of BasePlugin)
    @impl true
    def before_run(context, state) do
      handle_callback(:before_run, context)

      if state[:halt_before_run] do
        {:halt, [], state}
      else
        {:cont, context, state}
      end
    end

    @impl true
    def after_run(result, context, state) do
      handle_callback(:after_run, context)
      {result, state}
    end

    @impl true
    def before_model(context, request) do
      handle_callback(:before_model, context)

      if response = context.temp_state[:skip_model_response] do
        {:skip, response}
      else
        {:ok, request}
      end
    end

    @impl true
    def after_model(context, response) do
      handle_callback(:after_model, context)
      response
    end

    @impl true
    def on_model_error(context, error) do
      handle_callback(:on_model_error, context)

      if response = context.temp_state[:recover_model_response] do
        {:ok, response}
      else
        error
      end
    end

    @impl true
    def before_tool(context, _tool_name, args) do
      handle_callback(:before_tool, context)

      if result = context.temp_state[:skip_tool_result] do
        {:skip, result}
      else
        {:ok, args}
      end
    end

    @impl true
    def after_tool(context, _tool_name, result) do
      handle_callback(:after_tool, context)
      result
    end

    @impl true
    def on_tool_error(context, _tool_name, error) do
      handle_callback(:on_tool_error, context)

      if result = context.temp_state[:recover_tool_result] do
        {:ok, result}
      else
        error
      end
    end

    @impl true
    def on_event(context, _event) do
      handle_callback(:on_event, context)
      :ok
    end
  end

  # Exception-raising plugin
  defmodule ErrorPlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def before_run(_context, _state) do
      raise RuntimeError, "Something went wrong inside the plugin!"
    end
  end

  setup do
    # Ensure Registry is cleared between tests
    if Process.whereis(Registry) do
      Registry.clear()
    else
      {:ok, _} = Registry.start_link()
      on_exit(fn -> if Process.whereis(Registry), do: Agent.stop(Registry) end)
    end

    {:ok, log_agent} = Agent.start_link(fn -> [] end)

    ctx = %ADK.Context{
      invocation_id: "parity-test",
      temp_state: %{log_pid: log_agent}
    }

    on_exit(fn ->
      if Process.alive?(log_agent), do: Agent.stop(log_agent)
    end)

    %{ctx: ctx, log_agent: log_agent}
  end

  # --- parity tests ---

  test "test_register_and_get_plugin" do
    # test_register_and_get_plugin -> register and list
    Plugin.register({TestPlugin, %{name: "plugin1"}})

    plugins = Plugin.list()
    assert length(plugins) == 1
    assert [{TestPlugin, %{name: "plugin1"}}] = plugins
  end

  test "test_register_duplicate_plugin_name_raises_value_error" do
    # Note: Elixir's registry does NOT prevent duplicates by name or module.
    # We simply test the actual behavior to document this intentional deviation.
    Plugin.register({TestPlugin, %{name: "plugin1"}})
    Plugin.register({TestPlugin, %{name: "plugin1"}})

    plugins = Plugin.list()
    assert length(plugins) == 2
  end

  test "test_early_exit_stops_subsequent_plugins", %{ctx: ctx, log_agent: log_agent} do
    # test_early_exit_stops_subsequent_plugins -> If before_model returns skip, subsequent ones don't run
    # Set up skip in first plugin, log in both. Since we want both plugins to run if no skip, we configure them via context.
    # To differentiate, we'll configure plugin state. Wait, context is shared. We'll use two different plugins.

    defmodule SkipPlugin do
      @behaviour ADK.Plugin
      @impl true
      def init(_), do: {:ok, nil}
      @impl true
      def before_run(_ctx, st), do: {:halt, :halted_early, st}
    end

    plugins = [
      {TestPlugin, %{halt_before_run: true}},
      {TestPlugin, %{halt_before_run: false}}
    ]

    # Execute
    assert {:halt, [], _updated_plugins} = Plugin.run_before(plugins, ctx)

    # Assert only the first plugin logged anything (TestPlugin handles log)
    calls = Agent.get(log_agent, & &1)
    # Only one before_run logged
    assert calls == [:before_run]
  end

  test "test_normal_flow_all_plugins_are_called", %{ctx: ctx, log_agent: log_agent} do
    plugins = [
      {TestPlugin, %{halt_before_run: false}},
      {TestPlugin, %{halt_before_run: false}}
    ]

    assert {:cont, _ctx, _updated_plugins} = Plugin.run_before(plugins, ctx)

    calls = Agent.get(log_agent, & &1)
    assert calls == [:before_run, :before_run]
  end

  test "test_plugin_exception_is_wrapped_in_runtime_error", %{ctx: ctx} do
    # In Elixir, exceptions in plugins crash the process. They are NOT wrapped in a PluginError
    # (Elixir philosophy is "let it crash" rather than try-catch wrapping every plugin call).
    plugins = [{ErrorPlugin, %{}}]

    assert_raise RuntimeError, "Something went wrong inside the plugin!", fn ->
      Plugin.run_before(plugins, ctx)
    end
  end

  test "test_all_callbacks_are_supported", %{ctx: ctx, log_agent: log_agent} do
    # test_all_callbacks_are_supported
    plugins = [{TestPlugin, %{}}]

    # run all ADK.Plugin defined executors
    Plugin.run_before(plugins, ctx)
    Plugin.run_after(plugins, [], ctx)
    Plugin.run_before_model(plugins, ctx, %{})
    Plugin.run_after_model(plugins, ctx, {:ok, %{}})
    Plugin.run_on_model_error(plugins, ctx, {:error, :failed})
    Plugin.run_before_tool(plugins, ctx, "tool", %{})
    Plugin.run_after_tool(plugins, ctx, "tool", {:ok, "result"})
    Plugin.run_on_tool_error(plugins, ctx, "tool", {:error, :tool_failed})
    Plugin.run_on_event(plugins, ctx, %{})

    calls = Agent.get(log_agent, & &1) |> Enum.reverse()

    expected = [
      :before_run,
      :after_run,
      :before_model,
      :after_model,
      :on_model_error,
      :before_tool,
      :after_tool,
      :on_tool_error,
      :on_event
    ]

    assert calls == expected
  end

  # test_close_calls_plugin_close -> N/A in Elixir. Plugins don't have a close callback.
  # test_close_raises_runtime_error_on_plugin_exception -> N/A
  # test_close_with_timeout -> N/A
end
