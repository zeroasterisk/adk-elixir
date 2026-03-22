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

  ### Per-model and per-tool hooks (stateless)

  These hooks are called inline during LLM agent execution. They do not carry
  plugin state (use ETS or GenServer in `init/1` for statefulness across calls):

  - `before_model/2` — called before each LLM call; can modify the request or skip
    the call entirely by returning a canned response
  - `after_model/2` — called after each LLM call; can transform the response
  - `before_tool/3` — called before each tool execution; can modify args or skip
    the tool call by returning a canned result
  - `after_tool/3` — called after each tool execution; can transform the result
  - `on_event/2` — called for each event emitted during execution; observe-only

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

        @impl true
        def before_model(context, request) do
          # Inject extra context into every model request
          {:ok, Map.put(request, :extra, "injected")}
        end

        @impl true
        def after_model(_context, response) do
          response
        end

        @impl true
        def before_tool(_context, tool_name, args) do
          IO.puts("Calling tool: \#{tool_name}")
          {:ok, args}
        end

        @impl true
        def after_tool(_context, _tool_name, result) do
          result
        end

        @impl true
        def on_event(_context, event) do
          IO.inspect(event, label: "event")
          :ok
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

  @doc """
  Called before each LLM model call.

  Return `{:ok, request}` to continue (possibly with a modified request), or
  `{:skip, response}` to skip the model call entirely and use the given response.

  The `response` in `{:skip, response}` should be `{:ok, map()}` or `{:error, term()}`.
  """
  @callback before_model(ADK.Context.t(), request :: map()) ::
              {:ok, map()} | {:skip, {:ok, map()} | {:error, term()}}

  @doc """
  Called after each LLM model call.

  Receives the raw LLM result and may return a transformed result.
  """
  @callback after_model(ADK.Context.t(), {:ok, map()} | {:error, term()}) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Called when an LLM model call fails.

  Return `{:ok, response}` to recover and use the fake response, or
  `{:error, new_error}` to continue the error chain.
  """
  @callback on_model_error(ADK.Context.t(), {:error, term()}) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Called before each tool execution.

  Return `{:ok, args}` to continue (possibly with modified args), or
  `{:skip, result}` to skip the tool and return the given result directly.
  """
  @callback before_tool(ADK.Context.t(), tool_name :: String.t(), args :: map()) ::
              {:ok, map()} | {:skip, ADK.Tool.result()}

  @doc """
  Called after each tool execution.

  Receives the tool result and may return a transformed result.
  """
  @callback after_tool(ADK.Context.t(), tool_name :: String.t(), ADK.Tool.result()) ::
              ADK.Tool.result()

  @doc """
  Called when a tool execution fails.

  Return `{:ok, response}` to recover and use the fake response, or
  `{:error, new_error}` to continue the error chain.
  """
  @callback on_tool_error(ADK.Context.t(), tool_name :: String.t(), {:error, term()}) ::
              ADK.Tool.result()

  @doc """
  Called for each event emitted during execution (observe-only).

  Always return `:ok`. Use this for logging, telemetry, or side effects.
  """
  @callback on_event(ADK.Context.t(), ADK.Event.t()) :: :ok

  @optional_callbacks [
    init: 1,
    before_run: 2,
    after_run: 3,
    before_model: 2,
    after_model: 2,
    on_model_error: 2,
    before_tool: 3,
    after_tool: 3,
    on_tool_error: 3,
    on_event: 2
  ]

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

  @doc """
  Run before_model hooks for all registered plugins.

  Returns `{:ok, final_request}` if all plugins continue, or
  `{:skip, response}` if any plugin short-circuits the model call.

  Plugins that don't implement `before_model/2` are skipped.
  """
  @spec run_before_model([{module(), state()}], ADK.Context.t(), map()) ::
          {:ok, map()} | {:skip, {:ok, map()} | {:error, term()}}
  def run_before_model(plugins, ctx, request) do
    Enum.reduce_while(plugins, {:ok, request}, fn {mod, _st}, {:ok, req} ->
      if function_exported?(mod, :before_model, 2) do
        case mod.before_model(ctx, req) do
          {:ok, new_req} -> {:cont, {:ok, new_req}}
          {:skip, response} -> {:halt, {:skip, response}}
        end
      else
        {:cont, {:ok, req}}
      end
    end)
  end

  @doc """
  Run after_model hooks for all registered plugins, threading the result through each.

  Plugins that don't implement `after_model/2` are skipped.
  """
  @spec run_after_model([{module(), state()}], ADK.Context.t(), {:ok, map()} | {:error, term()}) ::
          {:ok, map()} | {:error, term()}
  def run_after_model(plugins, ctx, response) do
    Enum.reduce(plugins, response, fn {mod, _st}, resp ->
      if function_exported?(mod, :after_model, 2) do
        mod.after_model(ctx, resp)
      else
        resp
      end
    end)
  end

  @doc """
  Run on_model_error hooks for all registered plugins, threading the error through each.

  If any plugin recovers the error and returns `{:ok, response}`, subsequent plugins
  are skipped for the error chain and the error is considered handled.
  """
  @spec run_on_model_error([{module(), state()}], ADK.Context.t(), {:error, term()}) ::
          {:ok, map()} | {:error, term()}
  def run_on_model_error(plugins, ctx, error) do
    Enum.reduce_while(plugins, error, fn {mod, _st}, current_err ->
      if function_exported?(mod, :on_model_error, 2) do
        case mod.on_model_error(ctx, current_err) do
          {:ok, response} -> {:halt, {:ok, response}}
          {:error, new_err} -> {:cont, {:error, new_err}}
        end
      else
        {:cont, current_err}
      end
    end)
  end

  @doc """
  Run before_tool hooks for all registered plugins.

  Returns `{:ok, final_args}` if all plugins continue, or
  `{:skip, result}` if any plugin short-circuits the tool call.

  Plugins that don't implement `before_tool/3` are skipped.
  """
  @spec run_before_tool([{module(), state()}], ADK.Context.t(), String.t(), map()) ::
          {:ok, map()} | {:skip, ADK.Tool.result()}
  def run_before_tool(plugins, ctx, tool_name, args) do
    Enum.reduce_while(plugins, {:ok, args}, fn {mod, _st}, {:ok, current_args} ->
      if function_exported?(mod, :before_tool, 3) do
        case mod.before_tool(ctx, tool_name, current_args) do
          {:ok, new_args} -> {:cont, {:ok, new_args}}
          {:skip, result} -> {:halt, {:skip, result}}
        end
      else
        {:cont, {:ok, current_args}}
      end
    end)
  end

  @doc """
  Run after_tool hooks for all registered plugins, threading the result through each.

  Plugins that don't implement `after_tool/3` are skipped.
  """
  @spec run_after_tool([{module(), state()}], ADK.Context.t(), String.t(), ADK.Tool.result()) ::
          ADK.Tool.result()
  def run_after_tool(plugins, ctx, tool_name, result) do
    Enum.reduce(plugins, result, fn {mod, _st}, res ->
      if function_exported?(mod, :after_tool, 3) do
        mod.after_tool(ctx, tool_name, res)
      else
        res
      end
    end)
  end

  @doc """
  Run on_tool_error hooks for all registered plugins, threading the error through each.
  """
  @spec run_on_tool_error([{module(), state()}], ADK.Context.t(), String.t(), {:error, term()}) ::
          ADK.Tool.result()
  def run_on_tool_error(plugins, ctx, tool_name, error) do
    Enum.reduce_while(plugins, error, fn {mod, _st}, current_err ->
      if function_exported?(mod, :on_tool_error, 3) do
        case mod.on_tool_error(ctx, tool_name, current_err) do
          {:ok, response} -> {:halt, {:ok, response}}
          {:error, new_err} -> {:cont, {:error, new_err}}
        end
      else
        {:cont, current_err}
      end
    end)
  end

  @doc """
  Run on_event hooks for all registered plugins.

  All plugins that implement `on_event/2` are called. Errors are ignored.
  Always returns `:ok`.

  Plugins that don't implement `on_event/2` are skipped.
  """
  @spec run_on_event([{module(), state()}], ADK.Context.t(), ADK.Event.t()) :: :ok
  def run_on_event(plugins, ctx, event) do
    Enum.each(plugins, fn {mod, _st} ->
      if function_exported?(mod, :on_event, 2) do
        mod.on_event(ctx, event)
      end
    end)

    :ok
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
