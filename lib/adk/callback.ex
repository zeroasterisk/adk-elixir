defmodule ADK.Callback do
  @moduledoc """
  Callback hooks for agent, model, and tool invocations.

  Callbacks allow intercepting and transforming execution at key points in the
  agent pipeline. Each callback receives a callback context and can either
  continue execution or halt it early.

  ## Callback Types

  - `before_agent/1` — called before an agent runs; can short-circuit with `{:halt, events}`
  - `after_agent/2` — called after an agent runs; can transform the resulting events
  - `before_model/1` — called before an LLM call; can short-circuit with `{:halt, response}`
  - `after_model/2` — called after an LLM call; can transform the response
  - `before_tool/1` — called before a tool runs; can short-circuit with `{:halt, result}`
  - `after_tool/2` — called after a tool runs; can transform the result

  ## Usage

      defmodule MyCallbacks do
        @behaviour ADK.Callback

        @impl true
        def before_agent(callback_ctx), do: {:cont, callback_ctx}

        @impl true
        def after_agent(events, _callback_ctx), do: events
      end

      # Pass callbacks to Runner.run/5
      ADK.Runner.run(runner, user_id, session_id, message, callbacks: [MyCallbacks])
  """

  @type callback_ctx :: %{
          :agent => any(),
          :context => ADK.Context.t(),
          optional(:request) => map(),
          optional(:tool) => map(),
          optional(:tool_args) => map()
        }

  @doc "Called before an agent executes. Return `{:cont, callback_ctx}` to continue or `{:halt, events}` to short-circuit."
  @callback before_agent(callback_ctx()) :: {:cont, callback_ctx()} | {:halt, [ADK.Event.t()]}

  @doc "Called after an agent executes. Receives the events and callback context; returns (possibly transformed) events."
  @callback after_agent([ADK.Event.t()], callback_ctx()) :: [ADK.Event.t()]

  @doc "Called before a model call. Return `{:cont, callback_ctx}` to continue or `{:halt, {:ok, response}}` to short-circuit."
  @callback before_model(callback_ctx()) ::
              {:cont, callback_ctx()} | {:halt, {:ok, map()} | {:error, term()}}

  @doc "Called after a model call. Receives the response and callback context; returns (possibly transformed) response."
  @callback after_model({:ok, map()} | {:error, term()}, callback_ctx()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Called when the LLM backend returns an error.

  Return one of:
  - `{:retry, callback_ctx}` — retry the LLM call
  - `{:fallback, {:ok, response}}` — use a fallback response
  - `{:error, reason}` — propagate the error (re-raise)
  """
  @callback on_model_error({:error, term()}, callback_ctx()) ::
              {:retry, callback_ctx()} | {:fallback, {:ok, map()}} | {:error, term()}

  @doc "Called before a tool executes. Return `{:cont, callback_ctx}` to continue or `{:halt, result}` to short-circuit."
  @callback before_tool(callback_ctx()) :: {:cont, callback_ctx()} | {:halt, ADK.Tool.result()}

  @doc "Called after a tool executes. Receives the result and callback context; returns (possibly transformed) result."
  @callback after_tool(ADK.Tool.result(), callback_ctx()) :: ADK.Tool.result()

  @doc """
  Called when a tool returns an error.

  Return one of:
  - `{:retry, callback_ctx}` — retry the tool call
  - `{:fallback, {:ok, result}}` — use a fallback result
  - `{:error, reason}` — propagate the error
  """
  @callback on_tool_error({:error, term()}, callback_ctx()) ::
              {:retry, callback_ctx()} | {:fallback, {:ok, term()}} | {:error, term()}

  @optional_callbacks [
    before_agent: 1,
    after_agent: 2,
    before_model: 1,
    after_model: 2,
    on_model_error: 2,
    before_tool: 1,
    after_tool: 2,
    on_tool_error: 2
  ]

  @doc """
  Run a list of "before" callbacks in order. Returns `{:cont, callback_ctx}` if all
  callbacks continue, or `{:halt, result}` on the first halt.
  """
  @spec run_before([module()], atom(), callback_ctx()) ::
          {:cont, callback_ctx()} | {:halt, term()}
  def run_before(callbacks, hook, callback_ctx) do
    Enum.reduce_while(callbacks, {:cont, callback_ctx}, fn mod, {:cont, ctx} ->
      if function_exported?(mod, hook, 1) do
        case apply(mod, hook, [ctx]) do
          {:cont, new_ctx} -> {:cont, {:cont, new_ctx}}
          {:halt, result} -> {:halt, {:halt, result}}
        end
      else
        {:cont, {:cont, ctx}}
      end
    end)
  end

  @doc """
  Run on_model_error callbacks. Returns `{:retry, callback_ctx}`, `{:fallback, {:ok, response}}`,
  or `{:error, reason}`. First callback to return non-error wins.
  """
  @spec run_on_error([module()], {:error, term()}, callback_ctx()) ::
          {:retry, callback_ctx()} | {:fallback, {:ok, map()}} | {:error, term()}
  def run_on_error(callbacks, error, callback_ctx) do
    Enum.reduce_while(callbacks, error, fn mod, err ->
      if function_exported?(mod, :on_model_error, 2) do
        case apply(mod, :on_model_error, [err, callback_ctx]) do
          {:retry, _} = result -> {:halt, result}
          {:fallback, _} = result -> {:halt, result}
          {:error, _} = new_err -> {:cont, new_err}
        end
      else
        {:cont, err}
      end
    end)
  end

  @doc """
  Run on_tool_error callbacks. Returns `{:retry, callback_ctx}`, `{:fallback, {:ok, result}}`,
  or `{:error, reason}`. First callback to return non-error wins.
  """
  @spec run_on_tool_error([module()], {:error, term()}, callback_ctx()) ::
          {:retry, callback_ctx()} | {:fallback, {:ok, term()}} | {:error, term()}
  def run_on_tool_error(callbacks, error, callback_ctx) do
    Enum.reduce_while(callbacks, error, fn mod, err ->
      if function_exported?(mod, :on_tool_error, 2) do
        case apply(mod, :on_tool_error, [err, callback_ctx]) do
          {:retry, _} = result -> {:halt, result}
          {:fallback, _} = result -> {:halt, result}
          {:error, _} = new_err -> {:cont, new_err}
        end
      else
        {:cont, err}
      end
    end)
  end

  @doc """
  Run a list of "after" callbacks in order, threading the result through each.
  """
  @spec run_after([module()], atom(), term(), callback_ctx()) :: term()
  def run_after(callbacks, hook, result, callback_ctx) do
    Enum.reduce(callbacks, result, fn mod, acc ->
      if function_exported?(mod, hook, 2) do
        apply(mod, hook, [acc, callback_ctx])
      else
        acc
      end
    end)
  end
end
