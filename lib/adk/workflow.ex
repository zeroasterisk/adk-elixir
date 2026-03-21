defmodule ADK.Workflow do
  @moduledoc """
  Graph-based workflow executor for composing agents into DAGs.

  `ADK.Workflow` goes beyond `SequentialAgent` and `ParallelAgent` by supporting
  arbitrary directed acyclic graphs with conditional edges, fan-out/fan-in,
  collaboration modes, and checkpointing.

  Inspired by ADK 2.0's graph-based workflow system, built with idiomatic
  Elixir and OTP patterns.

  ## Quick Start

      # Define agents
      classifier = ADK.Agent.Custom.new(
        name: "classifier",
        handler: fn _ctx -> [ADK.Event.new(author: "classifier", content: ...)] end
      )

      handler = ADK.Agent.Custom.new(
        name: "handler",
        handler: fn _ctx -> [ADK.Event.new(author: "handler", content: ...)] end
      )

      # Build workflow
      workflow = ADK.Workflow.new(
        name: "my_pipeline",
        edges: [{:START, :classifier, :handler, :END}],
        nodes: %{classifier: classifier, handler: handler}
      )

      # Run it
      events = ADK.Workflow.run(workflow, ctx)

  ## Edge Syntax

  - Sequential chain: `{:START, :a, :b, :c, :END}`
  - Parallel branches: `[{:START, :a, :join}, {:START, :b, :join}, {:join, :END}]`
  - Conditional: `{:router, %{"bug" => :bug_handler, "support" => :support_handler}}`

  ## Collaboration Modes

  - `:pipeline` — sequential output chaining (default)
  - `:debate` — parallel processing, results compared
  - `:vote` — parallel processing, majority wins
  - `:review` — one produces, others critique
  """

  alias ADK.Workflow.{Graph, Executor, Collaboration}

  @enforce_keys [:name]
  defstruct [
    :name,
    :parent_agent,
    description: "Graph-based workflow",
    sub_agents: [],
    graph: nil,
    edges: [],
    nodes: %{},
    collaboration: :pipeline,
    checkpoint_store: ADK.Workflow.Checkpoint.EtsStore,
    node_timeout: 60_000,
    timeout: 300_000
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          sub_agents: [ADK.Agent.t()],
          graph: Graph.t() | nil,
          edges: [tuple()],
          nodes: map(),
          collaboration: Collaboration.mode(),
          checkpoint_store: module(),
          node_timeout: pos_integer(),
          timeout: pos_integer()
        }

  @doc """
  Create a new workflow.

  ## Options

  - `:name` (required) — workflow identifier
  - `:edges` — list of edge tuples defining the graph
  - `:nodes` — map of node_id => agent/function definitions
  - `:description` — human-readable description
  - `:collaboration` — collaboration mode (default: `:pipeline`)
  - `:checkpoint_store` — checkpoint backend (default: ETS)
  - `:node_timeout` — per-node timeout in ms (default: 60_000)
  - `:timeout` — global timeout in ms (default: 300_000)

  ## Examples

      iex> w = ADK.Workflow.new(name: "test", edges: [{:START, :a, :END}])
      iex> w.name
      "test"
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    workflow = struct!(__MODULE__, opts)
    graph = build_graph(workflow.edges, workflow.nodes)
    %{workflow | graph: graph}
  end

  @doc """
  Create a workflow with validation. Returns `{:ok, workflow}` or `{:error, reason}`.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(opts) do
    workflow = new(opts)

    case Graph.validate(workflow.graph) do
      :ok -> {:ok, workflow}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  @doc """
  Run the workflow, returning a list of events.

  ## Options

  - `:resume_id` — resume from a previous execution's checkpoints
  """
  @spec run(t(), ADK.Context.t(), keyword()) :: [ADK.Event.t()]
  def run(%__MODULE__{} = workflow, %ADK.Context{} = ctx, opts \\ []) do
    Executor.run(
      workflow.graph,
      ctx,
      Keyword.merge(
        [
          checkpoint_store: workflow.checkpoint_store,
          collaboration: workflow.collaboration,
          timeout: workflow.timeout,
          node_timeout: workflow.node_timeout
        ],
        opts
      )
    )
  end

  @doc """
  Validate the workflow graph. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{graph: graph}), do: Graph.validate(graph)

  @doc "Clone this workflow with optional updates. See `ADK.Agent.Clone`."
  def clone(workflow, update \\ nil), do: ADK.Agent.Clone.clone(workflow, update)

  # ── ADK.Agent Protocol Implementation ──

  defimpl ADK.Agent do
    def name(workflow), do: workflow.name
    def description(workflow), do: workflow.description

    def sub_agents(workflow) do
      workflow.nodes
      |> Map.values()
      |> Enum.filter(fn node ->
        ADK.Agent.impl_for(node) != nil
      end)
    end

    def run(workflow, ctx) do
      ADK.Workflow.run(workflow, ctx)
    end
  end

  # ── Private ──

  # Expand chain tuples into pairwise edges
  # {:START, :a, :b, :END} → [{:START, :a}, {:a, :b}, {:b, :END}]
  defp build_graph(edges, nodes) do
    expanded = Enum.flat_map(edges, &expand_edge/1)
    Graph.build(expanded, nodes)
  end

  defp expand_edge({from, %{} = routes}) do
    # Conditional edge — keep as-is
    [{from, routes}]
  end

  defp expand_edge(tuple) when is_tuple(tuple) do
    elements = Tuple.to_list(tuple)

    case elements do
      [from, %{} = routes] ->
        [{from, routes}]

      [from, to] ->
        [{from, to}]

      chain when length(chain) >= 2 ->
        chain
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> {a, b} end)
    end
  end
end
