defmodule ADK.Plugin.Registry do
  @moduledoc """
  Agent-based registry for global plugins.

  Stores initialized `{module, state}` tuples. Start as part of your
  application supervision tree or manually with `start_link/1`.
  """

  use Agent

  @doc "Start the plugin registry."
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc """
  Register a plugin. Accepts a module or `{module, config}`.

  Calls `init/1` on the module if implemented, otherwise uses config as state.
  """
  @spec register(module() | {module(), term()}) :: :ok
  def register(plugin) do
    {mod, config} = normalize(plugin)

    state =
      if function_exported?(mod, :init, 1) do
        {:ok, st} = mod.init(config)
        st
      else
        config
      end

    Agent.update(__MODULE__, fn plugins -> plugins ++ [{mod, state}] end)
  end

  @doc "List all registered plugins as `[{module, state}]`."
  @spec list() :: [{module(), term()}]
  def list do
    Agent.get(__MODULE__, & &1)
  end

  @doc "Clear all registered plugins."
  @spec clear() :: :ok
  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end

  defp normalize(mod) when is_atom(mod), do: {mod, %{}}
  defp normalize({mod, config}), do: {mod, config}
end
