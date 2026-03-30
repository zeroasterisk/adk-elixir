defmodule ADK.PluginTest do
  use ExUnit.Case, async: false

  alias ADK.Plugin
  alias ADK.Plugin.Registry

  defmodule PassthroughPlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def before_run(context, state) do
      send(state.test_pid, {:before_run, state.name})
      {:cont, context, state}
    end

    @impl true
    def after_run(result, _context, state) do
      send(state.test_pid, {:after_run, state.name})
      {result, state}
    end
  end

  defmodule HaltingPlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def before_run(_context, state) do
      send(state.test_pid, {:halted, state.name})
      {:halt, [{:halted_by, state.name}], state}
    end
  end

  defmodule TransformPlugin do
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def after_run(result, _context, state) do
      {result ++ [:transformed], Map.update(state, :count, 1, &(&1 + 1))}
    end
  end

  defmodule NoCallbacksPlugin do
    @behaviour ADK.Plugin
    # No callbacks implemented — tests optional_callbacks
  end

  setup do
    # Registry is started by ADK.Application; just clear it between tests
    if Process.whereis(Registry) do
      Registry.clear()
    else
      {:ok, _} = Registry.start_link()
      on_exit(fn -> if Process.whereis(Registry), do: Agent.stop(Registry) end)
    end

    :ok
  end

  describe "Registry" do
    test "register and list plugins" do
      Registry.register({PassthroughPlugin, %{test_pid: self(), name: "p1"}})

      assert [{PassthroughPlugin, %{name: "p1"}}] =
               Registry.list() |> Enum.map(fn {m, s} -> {m, Map.delete(s, :test_pid)} end)
    end

    test "clear removes all plugins" do
      Registry.register({PassthroughPlugin, %{test_pid: self(), name: "p1"}})
      Registry.clear()
      assert [] = Registry.list()
    end

    test "register module without config" do
      Registry.register(NoCallbacksPlugin)
      assert [{NoCallbacksPlugin, []}] = Registry.list()
    end
  end

  describe "run_before/2" do
    test "continues through all plugins" do
      plugins = [
        {PassthroughPlugin, %{test_pid: self(), name: "a"}},
        {PassthroughPlugin, %{test_pid: self(), name: "b"}}
      ]

      ctx = %ADK.Context{invocation_id: "test"}
      assert {:cont, ^ctx, updated} = Plugin.run_before(plugins, ctx)
      assert length(updated) == 2
      assert_received {:before_run, "a"}
      assert_received {:before_run, "b"}
    end

    test "halts on first halting plugin" do
      plugins = [
        {PassthroughPlugin, %{test_pid: self(), name: "a"}},
        {HaltingPlugin, %{test_pid: self(), name: "halt"}},
        {PassthroughPlugin, %{test_pid: self(), name: "c"}}
      ]

      ctx = %ADK.Context{invocation_id: "test"}
      assert {:halt, [{:halted_by, "halt"}], updated} = Plugin.run_before(plugins, ctx)
      assert length(updated) == 3
      assert_received {:before_run, "a"}
      assert_received {:halted, "halt"}
      refute_received {:before_run, "c"}
    end

    test "skips plugins without before_run" do
      plugins = [{NoCallbacksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "test"}
      assert {:cont, ^ctx, [{NoCallbacksPlugin, %{}}]} = Plugin.run_before(plugins, ctx)
    end
  end

  describe "run_after/3" do
    test "transforms result through plugins" do
      plugins = [
        {TransformPlugin, %{}},
        {TransformPlugin, %{}}
      ]

      ctx = %ADK.Context{invocation_id: "test"}
      {result, _updated} = Plugin.run_after(plugins, [:event1], ctx)
      assert result == [:event1, :transformed, :transformed]
    end

    test "skips plugins without after_run" do
      plugins = [{NoCallbacksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "test"}
      {result, _} = Plugin.run_after(plugins, [:event1], ctx)
      assert result == [:event1]
    end
  end

  describe "register/1 and list/0 convenience" do
    test "delegates to registry" do
      Plugin.register({PassthroughPlugin, %{test_pid: self(), name: "x"}})
      assert [{PassthroughPlugin, _}] = Plugin.list()
    end
  end
end
