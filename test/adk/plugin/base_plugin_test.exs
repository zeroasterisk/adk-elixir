defmodule ADK.Plugin.BasePluginTest do
  use ExUnit.Case, async: true

  # TestablePlugin: equivalent to TestablePlugin in Python
  # (No callbacks implemented, represents the "default" state of a plugin)
  defmodule TestablePlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}
  end

  # FullOverridePlugin: equivalent to FullOverridePlugin in Python
  # (Overrides all optional callbacks to return a specific "overridden" response)
  defmodule FullOverridePlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def before_run(context, state) do
      # Return a special cont payload to prove we ran
      {:cont, Map.put(context, :overridden, "before_run"), state}
    end

    @impl true
    def after_run(result, _context, state) do
      # Return a special result payload to prove we ran
      {result ++ [%{type: :overridden, value: "after_run"}], state}
    end

    @impl true
    def before_model(_context, request) do
      {:ok, Map.put(request, :overridden, "before_model")}
    end

    @impl true
    def after_model(_context, {:ok, response}) do
      {:ok, Map.put(response, :overridden, "after_model")}
    end

    @impl true
    def on_model_error(_context, {:error, _error}) do
      {:error, "overridden_on_model_error"}
    end

    @impl true
    def before_tool(_context, _tool_name, args) do
      {:ok, Map.put(args, :overridden, "before_tool")}
    end

    @impl true
    def after_tool(_context, _tool_name, {:ok, result}) do
      {:ok, Map.put(result, :overridden, "after_tool")}
    end

    @impl true
    def on_tool_error(_context, _tool_name, {:error, _error}) do
      {:error, "overridden_on_tool_error"}
    end

    @impl true
    def on_event(_context, event) do
      # Send a message to self so we can assert on_event was called
      send(self(), {:event_overridden, event})
      :ok
    end
  end

  describe "plugin defaults" do
    test "test_base_plugin_initialization" do
      # Equivalent to test_base_plugin_initialization
      # Tests that a plugin is initialized with the correct config/state
      assert {:ok, %{name: "my_test_plugin"}} = TestablePlugin.init(%{name: "my_test_plugin"})
    end

    test "test_base_plugin_default_callbacks_return_none (skip missing callbacks)" do
      # Equivalent to test_base_plugin_default_callbacks_return_none
      # Tests that plugins without callbacks correctly pass through or return default responses
      plugins = [{TestablePlugin, %{}}]
      context = %{}

      # before_run passes context through unchanged
      assert {:cont, ^context, ^plugins} = ADK.Plugin.run_before(plugins, context)

      # after_run passes result through unchanged
      events = []
      assert {^events, ^plugins} = ADK.Plugin.run_after(plugins, events, context)

      # before_model passes request through unchanged
      request = %{prompt: "hello"}
      assert {:ok, ^request} = ADK.Plugin.run_before_model(plugins, context, request)

      # after_model passes response through unchanged
      response = {:ok, %{text: "hi"}}
      assert ^response = ADK.Plugin.run_after_model(plugins, context, response)

      # on_model_error passes error through unchanged
      error = {:error, "failed"}
      assert ^error = ADK.Plugin.run_on_model_error(plugins, context, error)

      # before_tool passes args through unchanged
      args = %{x: 1}
      assert {:ok, ^args} = ADK.Plugin.run_before_tool(plugins, context, "my_tool", args)

      # after_tool passes result through unchanged
      result = {:ok, %{y: 2}}
      assert ^result = ADK.Plugin.run_after_tool(plugins, context, "my_tool", result)

      # on_tool_error passes error through unchanged
      tool_error = {:error, "tool failed"}
      assert ^tool_error = ADK.Plugin.run_on_tool_error(plugins, context, "my_tool", tool_error)

      # on_event returns :ok
      assert :ok == ADK.Plugin.run_on_event(plugins, context, %{type: :some_event})
    end
  end

  describe "plugin overrides" do
    test "test_base_plugin_all_callbacks_can_be_overridden" do
      # Equivalent to test_base_plugin_all_callbacks_can_be_overridden
      # Verifies that a user can create a plugin and that all overridden methods are correctly called
      plugins = [{FullOverridePlugin, %{}}]
      context = %{}

      # before_run
      assert {:cont, new_context, ^plugins} = ADK.Plugin.run_before(plugins, context)
      assert new_context.overridden == "before_run"

      # after_run
      events = [%{type: :test}]
      assert {new_events, ^plugins} = ADK.Plugin.run_after(plugins, events, context)
      assert length(new_events) == 2
      assert List.last(new_events) == %{type: :overridden, value: "after_run"}

      # before_model
      request = %{prompt: "hello"}
      assert {:ok, new_request} = ADK.Plugin.run_before_model(plugins, context, request)
      assert new_request.overridden == "before_model"

      # after_model
      response = {:ok, %{text: "hi"}}
      assert {:ok, new_response} = ADK.Plugin.run_after_model(plugins, context, response)
      assert new_response.overridden == "after_model"

      # on_model_error
      error = {:error, "failed"}
      assert {:error, "overridden_on_model_error"} = ADK.Plugin.run_on_model_error(plugins, context, error)

      # before_tool
      args = %{x: 1}
      assert {:ok, new_args} = ADK.Plugin.run_before_tool(plugins, context, "my_tool", args)
      assert new_args.overridden == "before_tool"

      # after_tool
      result = {:ok, %{y: 2}}
      assert {:ok, new_result} = ADK.Plugin.run_after_tool(plugins, context, "my_tool", result)
      assert new_result.overridden == "after_tool"

      # on_tool_error
      tool_error = {:error, "tool failed"}
      assert {:error, "overridden_on_tool_error"} = ADK.Plugin.run_on_tool_error(plugins, context, "my_tool", tool_error)

      # on_event
      event = %{type: :my_event}
      assert :ok == ADK.Plugin.run_on_event(plugins, context, event)
      assert_receive {:event_overridden, ^event}
    end
  end
end
