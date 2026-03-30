defmodule ADK.Workflow.Graph do
  @moduledoc """
  Graph data structure for workflow definitions.

  Represents a directed acyclic graph (DAG) of nodes and edges. Supports
  unconditional edges, conditional routing (map-based), fan-out (parallel
  branches), and fan-in (join nodes).

  ## Node Types

  - Agent structs (any `ADK.Agent.t()`)
  - Anonymous functions (`fn context -> events end`)
  - `:START` / `:END` sentinel atoms

  ## Edge Types

  - Unconditional: `{from, to}` — always traverse
  - Conditional: `{from, %{"route_key" => to_node}}` — route based on context
  """

  @enforce_keys [:nodes, :edges]
  defstruct [:nodes, :edges]

  @type node_id :: atom() | String.t()
  @type edge :: {node_id(), node_id()} | {node_id(), %{String.t() => node_id()}}

  @type t :: %__MODULE__{
          nodes: %{node_id() => any()},
          edges: [edge()]
        }

  @doc """
  Build a graph from edge tuples.

  Edge tuples are `{from, to}` for unconditional or `{from, %{...}}` for conditional.
  Nodes are extracted automatically from edges.

  ## Examples

      iex> g = ADK.Workflow.Graph.build([{:START, :a}, {:a, :END}], %{a: agent})
      iex> Map.keys(g.nodes) |> Enum.sort()
      [:END, :START, :a]
  """
  @spec build([edge()], %{node_id() => any()}) :: t()
  def build(edges, node_defs \\ %{}) do
    # Extract all node IDs from edges
    edge_node_ids = extract_node_ids(edges)
    all_node_ids = Enum.uniq(edge_node_ids ++ Map.keys(node_defs))

    # Build nodes map: sentinels + user-provided definitions
    nodes =
      all_node_ids
      |> Enum.reduce(%{}, fn id, acc ->
        node = Map.get(node_defs, id, id)
        Map.put(acc, id, node)
      end)

    %__MODULE__{nodes: nodes, edges: edges}
  end

  @doc """
  Validate the graph structure.

  Checks:
  - Has at least one `:START` edge
  - All edge targets reference known nodes
  - No cycles (DAG enforcement)
  - No unreachable nodes (except `:START`)

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = graph) do
    with :ok <- validate_start(graph),
         :ok <- validate_references(graph),
         :ok <- validate_no_cycles(graph),
         :ok <- validate_reachability(graph) do
      :ok
    end
  end

  @doc """
  Return successors of a node. For conditional edges, returns all possible targets.
  """
  @spec successors(t(), node_id()) :: [node_id()]
  def successors(%__MODULE__{edges: edges}, node_id) do
    edges
    |> Enum.flat_map(fn
      {^node_id, %{} = routes} -> Map.values(routes)
      {^node_id, target} -> [target]
      _ -> []
    end)
    |> Enum.uniq()
  end

  @doc """
  Return predecessors of a node.
  """
  @spec predecessors(t(), node_id()) :: [node_id()]
  def predecessors(%__MODULE__{edges: edges}, node_id) do
    edges
    |> Enum.flat_map(fn
      {from, %{} = routes} ->
        if node_id in Map.values(routes), do: [from], else: []

      {from, ^node_id} ->
        [from]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  @doc """
  Find nodes with multiple predecessors (join points).
  """
  @spec join_nodes(t()) :: [node_id()]
  def join_nodes(%__MODULE__{} = graph) do
    graph.nodes
    |> Map.keys()
    |> Enum.filter(fn id -> length(predecessors(graph, id)) > 1 end)
  end

  @doc """
  Find edges that are conditional (map-based routing).
  """
  @spec conditional_edges(t()) :: [{node_id(), %{String.t() => node_id()}}]
  def conditional_edges(%__MODULE__{edges: edges}) do
    Enum.filter(edges, fn
      {_from, %{} = _routes} -> true
      _ -> false
    end)
  end

  @doc """
  Return the edge definition for a given source node.
  Returns `{:unconditional, [targets]}` or `{:conditional, route_map}`.
  """
  @spec outgoing(t(), node_id()) ::
          {:unconditional, [node_id()]} | {:conditional, %{String.t() => node_id()}} | :none
  def outgoing(%__MODULE__{edges: edges}, node_id) do
    matching =
      Enum.filter(edges, fn
        {^node_id, _} -> true
        _ -> false
      end)

    case matching do
      [] ->
        :none

      edges_list ->
        # Check if any are conditional
        conditional = Enum.find(edges_list, fn {_, target} -> is_map(target) end)

        if conditional do
          {_, routes} = conditional
          {:conditional, routes}
        else
          targets = Enum.map(edges_list, fn {_, target} -> target end)
          {:unconditional, targets}
        end
    end
  end

  # ── Private ──

  defp extract_node_ids(edges) do
    edges
    |> Enum.flat_map(fn
      {from, %{} = routes} -> [from | Map.values(routes)]
      {from, to} -> [from, to]
    end)
    |> Enum.uniq()
  end

  defp validate_start(%{edges: edges}) do
    has_start =
      Enum.any?(edges, fn
        {:START, _} -> true
        _ -> false
      end)

    if has_start, do: :ok, else: {:error, "graph must have at least one :START edge"}
  end

  defp validate_references(%{nodes: nodes, edges: edges}) do
    known = MapSet.new(Map.keys(nodes))

    missing =
      edges
      |> Enum.flat_map(fn
        {from, %{} = routes} -> [from | Map.values(routes)]
        {from, to} -> [from, to]
      end)
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.uniq()

    if missing == [],
      do: :ok,
      else: {:error, "unknown nodes referenced in edges: #{inspect(missing)}"}
  end

  defp validate_no_cycles(%{edges: edges} = graph) do
    node_ids = extract_node_ids(edges)
    # DFS-based cycle detection
    case detect_cycle(graph, node_ids) do
      nil -> :ok
      cycle -> {:error, "cycle detected: #{inspect(cycle)}"}
    end
  end

  defp detect_cycle(graph, node_ids) do
    Enum.reduce_while(node_ids, {MapSet.new(), MapSet.new()}, fn node, {visited, _in_stack} ->
      if MapSet.member?(visited, node) do
        {:cont, {visited, MapSet.new()}}
      else
        case dfs_visit(graph, node, visited, MapSet.new(), []) do
          {:cycle, path} -> {:halt, path}
          {:ok, new_visited} -> {:cont, {new_visited, MapSet.new()}}
        end
      end
    end)
    |> case do
      {_visited, _stack} -> nil
      path -> path
    end
  end

  defp dfs_visit(graph, node, visited, in_stack, path) do
    if MapSet.member?(in_stack, node) do
      {:cycle, Enum.reverse([node | path])}
    else
      if MapSet.member?(visited, node) do
        {:ok, visited}
      else
        new_stack = MapSet.put(in_stack, node)
        new_visited = MapSet.put(visited, node)

        succs = successors(graph, node)

        Enum.reduce_while(succs, {:ok, new_visited}, fn succ, {:ok, v} ->
          case dfs_visit(graph, succ, v, new_stack, [node | path]) do
            {:cycle, _} = cycle -> {:halt, cycle}
            {:ok, v2} -> {:cont, {:ok, v2}}
          end
        end)
      end
    end
  end

  defp validate_reachability(%{nodes: nodes} = graph) do
    node_ids = Map.keys(nodes) |> MapSet.new()

    # BFS from :START
    reachable = bfs(graph, [:START], MapSet.new())

    unreachable =
      MapSet.difference(node_ids, reachable)
      |> MapSet.to_list()
      |> Enum.reject(&(&1 == :START))

    if unreachable == [],
      do: :ok,
      else: {:error, "unreachable nodes: #{inspect(unreachable)}"}
  end

  defp bfs(_graph, [], visited), do: visited

  defp bfs(graph, [node | rest], visited) do
    if MapSet.member?(visited, node) do
      bfs(graph, rest, visited)
    else
      new_visited = MapSet.put(visited, node)
      succs = successors(graph, node)
      bfs(graph, rest ++ succs, new_visited)
    end
  end
end
