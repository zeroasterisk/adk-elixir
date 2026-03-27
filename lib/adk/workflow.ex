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
  Add edges and node definitions to an existing workflow.

  ## Examples

      iex> w = ADK.Workflow.new(name: "test")
      iex> w = ADK.Workflow.add(w, {:START, :a, :END}, %{a: my_agent})
      iex> length(w.graph.edges)
      2
  """
  @spec add(t(), tuple() | [tuple()], map()) :: t()
  def add(%__MODULE__{} = workflow, edge_or_edges, node_defs \\ %{}) do
    incoming_edges = if is_list(edge_or_edges), do: edge_or_edges, else: [edge_or_edges]

    new_edges = workflow.edges ++ incoming_edges
    new_nodes = Map.merge(workflow.nodes, node_defs)

    graph = build_graph(new_edges, new_nodes)

    %{workflow | edges: new_edges, nodes: new_nodes, graph: graph}
  end

  @doc """
  Run the workflow, returning a list of events.

  ## Options

  - `:resume_id` — resume from a previous execution's checkpoints
  """
  @spec run(t(), ADK.Context.t(), keyword()) :: [ADK.Event.t()]
  @spec run(atom() | String.t(), function(), function() | nil) :: ADK.Workflow.Step.t()
  def run(arg1, arg2, arg3 \\ nil)

  def run(%__MODULE__{} = workflow, %ADK.Context{} = ctx, opts) do
    opts = opts || []
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

  def run(name, run_fun, compensate_fun) when is_atom(name) or is_binary(name) do
    ADK.Workflow.Step.new(name, run_fun, compensate_fun)
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

  @doc """
  Compile an agent-generated plan into an executable workflow DAG.

  The plan is a map with a `"steps"` key containing a list of step
  definitions. Each step has an `"id"` and optional `"depends_on"` list.

  Returns `{:ok, workflow}` or `{:error, reason}`.

  ADK Elixir extension — no Python ADK equivalent exists.

  ## Examples

      iex> plan = %{"steps" => [
      ...>   %{"id" => "a", "action" => "execute"},
      ...>   %{"id" => "b", "action" => "execute", "depends_on" => ["a"]}
      ...> ]}
      iex> {:ok, workflow} = ADK.Workflow.from_plan(plan)
      iex> workflow.name
      "plan"
  """
  @spec from_plan(map()) :: {:ok, t()} | {:error, String.t()}
  def from_plan(%{"steps" => steps}) when is_list(steps) do
    ids = Enum.map(steps, & &1["id"])

    # Check for duplicates
    case ids -- Enum.uniq(ids) do
      [dup | _] ->
        {:error, "Duplicate step id: #{dup}"}

      [] ->
        # Check for undefined dependencies
        id_set = MapSet.new(ids)

        undefined =
          Enum.find_value(steps, fn step ->
            deps = step["depends_on"] || []
            bad = Enum.find(deps, &(not MapSet.member?(id_set, &1)))
            if bad, do: {step["id"], bad}
          end)

        case undefined do
          {step_id, dep_id} ->
            {:error, "Step #{step_id} depends on undefined step: #{dep_id}"}

          nil ->
            # Build edges: for each step, create edges from its dependencies
            # Steps with no deps get an edge from :START
            # Steps that nothing depends on get an edge to :END
            dep_edges =
              Enum.flat_map(steps, fn step ->
                deps = step["depends_on"] || []
                step_atom = String.to_atom(step["id"])

                if deps == [] do
                  [{:START, step_atom}]
                else
                  Enum.map(deps, &{String.to_atom(&1), step_atom})
                end
              end)

            # Find terminal steps (not depended on by anything)
            all_deps =
              steps
              |> Enum.flat_map(fn s -> s["depends_on"] || [] end)
              |> MapSet.new()

            terminal_edges =
              steps
              |> Enum.filter(fn s -> not MapSet.member?(all_deps, s["id"]) end)
              |> Enum.map(fn s -> {String.to_atom(s["id"]), :END} end)

            edges = dep_edges ++ terminal_edges

            # Create placeholder nodes (Custom agents with passthrough handlers)
            nodes =
              Map.new(steps, fn step ->
                atom = String.to_atom(step["id"])

                {atom,
                 ADK.Agent.Custom.new(
                   name: step["id"],
                   run_fn: fn _agent, _ctx ->
                     [ADK.Event.new(author: step["id"], content: "Executed #{step["id"]}")]
                   end
                 )}
              end)

            {:ok,
             %__MODULE__{
               name: "plan",
               edges: edges,
               nodes: nodes,
               graph: Graph.build(edges)
             }}
        end
    end
  end

  def from_plan(_), do: {:error, "Plan must have a \"steps\" key with a list of steps"}
end
