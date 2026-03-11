defmodule ADK.Plugin do
  @moduledoc """
  Global plugin behaviour for intercepting the Runner pipeline.

  Unlike callbacks (per-invocation, per-agent), plugins are **global** — registered
  at the application level and applied to every `Runner.run/5` call. Plugins can
  inspect/transform the context before execution, and inspect/transform results after.

  ## Behaviour

  Implement any subset of callbacks:

  - `init/1` — initialize plugin state from config, return `{:ok, state}`
  - `before_run/2` — called before Runner executes, receives `{context, plugin_state}`,
    returns `{:cont, context, state}` or `{:halt, result, state}`
  - `after_run/3` — called after Runner executes, receives `{result, context, plugin_state}`,
    returns `{result, state}`

  ## Example

      defmodule MyPlugin do
        @behaviour ADK.Plugin

        @impl true
        def init(config), do: {:ok, config}

        @impl true
        def before_run(context, state) do
          {:cont, context, state}
        end

        @impl true
        def after_run(result, _context, state) do
          {result, state}
        end
      end

      # Register globally
      ADK.Plugin.Registry.start_link([])
      ADK.Plugin.register({MyPlugin, my_config: true})
  """

  @type state :: term()

  @doc "Initialize plugin state from config. Return `{:ok, state}`."
  @callback init(config :: term()) :: {:ok, state()}

  @doc """
  Called before Runner.run executes the agent.

  Return `{:cont, context, new_state}` to continue or `{:halt, result, new_state}` to short-circuit.
  """
  @callback before_run(ADK.Context.t(), state()) ::
              {:cont, ADK.Context.t(), state()} | {:halt, term(), state()}

  @doc """
  Called after Runner.run executes the agent.

  Receives the result (list of events), the context, and plugin state.
  Return `{result, new_state}`.
  """
  @callback after_run([ADK.Event.t()], ADK.Context.t(), state()) ::
              {[ADK.Event.t()], state()}

  @optional_callbacks [init: 1, before_run: 2, after_run: 3]

  @doc """
  Run before_run hooks for a list of `{module, state}` tuples.

  Returns `{:cont, context, updated_plugins}` or `{:halt, result, updated_plugins}`.
  """
  @spec run_before([{module(), state()}], ADK.Context.t()) ::
          {:cont, ADK.Context.t(), [{module(), state()}]}
          | {:halt, term(), [{module(), state()}]}
  def run_before(plugins, context) do
    Enum.reduce_while(plugins, {:cont, context, []}, fn {mod, st}, {:cont, ctx, acc} ->
      if function_exported?(mod, :before_run, 2) do
        case mod.before_run(ctx, st) do
          {:cont, new_ctx, new_st} ->
            {:cont, {:cont, new_ctx, acc ++ [{mod, new_st}]}}

          {:halt, result, new_st} ->
            # Remaining plugins keep their old state
            remaining = plugins |> Enum.drop(length(acc) + 1)
            {:halt, {:halt, result, acc ++ [{mod, new_st}] ++ remaining}}
        end
      else
        {:cont, {:cont, ctx, acc ++ [{mod, st}]}}
      end
    end)
  end

  @doc """
  Run after_run hooks for a list of `{module, state}` tuples.

  Returns `{result, updated_plugins}`.
  """
  @spec run_after([{module(), state()}], [ADK.Event.t()], ADK.Context.t()) ::
          {[ADK.Event.t()], [{module(), state()}]}
  def run_after(plugins, result, context) do
    Enum.reduce(plugins, {result, []}, fn {mod, st}, {res, acc} ->
      if function_exported?(mod, :after_run, 3) do
        {new_res, new_st} = mod.after_run(res, context, st)
        {new_res, acc ++ [{mod, new_st}]}
      else
        {res, acc ++ [{mod, st}]}
      end
    end)
  end

  @doc "Register a plugin globally. Accepts `module` or `{module, config}`."
  @spec register(module() | {module(), term()}) :: :ok
  def register(plugin) do
    ADK.Plugin.Registry.register(plugin)
  end

  @doc "List all registered plugins as `[{module, state}]`."
  @spec list() :: [{module(), state()}]
  def list do
    ADK.Plugin.Registry.list()
  end
end
