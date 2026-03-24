defmodule ADK.Workflow.Graph.Runtime do
  @moduledoc """
  GenServer that wraps a graph and allows atomic mutations during execution.

  Maintains a history of graph states (up to 10) for undo/debugging.

  Net-new: not present in Python ADK.
  """

  use GenServer

  alias ADK.Workflow.Graph

  @max_history 10

  # ── Client API ──

  @doc "Start the runtime with an initial graph."
  @spec start_link(Graph.t(), GenServer.options()) :: GenServer.on_start()
  def start_link(%Graph{} = graph, opts \\ []) do
    GenServer.start_link(__MODULE__, graph, opts)
  end

  @doc "Get the current graph."
  @spec get(GenServer.server()) :: Graph.t()
  def get(pid) do
    GenServer.call(pid, :get)
  end

  @doc """
  Apply a mutation function atomically.

  The function receives the current graph and must return
  `{:ok, new_graph}` or `{:error, reason}`.
  """
  @spec mutate(GenServer.server(), (Graph.t() -> {:ok, Graph.t()} | {:error, any()})) ::
          :ok | {:error, any()}
  def mutate(pid, mutation_fn) when is_function(mutation_fn, 1) do
    GenServer.call(pid, {:mutate, mutation_fn})
  end

  @doc "Return list of past graph states (most recent first)."
  @spec history(GenServer.server()) :: [Graph.t()]
  def history(pid) do
    GenServer.call(pid, :history)
  end

  @doc "Rollback to the previous graph state."
  @spec rollback(GenServer.server()) :: :ok | {:error, :no_history}
  def rollback(pid) do
    GenServer.call(pid, :rollback)
  end

  # ── Server Callbacks ──

  @impl true
  def init(%Graph{} = graph) do
    {:ok, %{current: graph, history: []}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.current, state}
  end

  def handle_call({:mutate, fun}, _from, state) do
    case fun.(state.current) do
      {:ok, %Graph{} = new_graph} ->
        history = Enum.take([state.current | state.history], @max_history)
        {:reply, :ok, %{state | current: new_graph, history: history}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:rollback, _from, state) do
    case state.history do
      [] ->
        {:reply, {:error, :no_history}, state}

      [prev | rest] ->
        {:reply, :ok, %{state | current: prev, history: rest}}
    end
  end
end
