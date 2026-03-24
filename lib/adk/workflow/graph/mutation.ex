defmodule ADK.Workflow.Graph.Mutation do
  @moduledoc """
  Functional mutations for workflow graphs.

  All operations return a new `%Graph{}` — the original is never modified.
  Mutations validate the result (no cycles, no dangling edges).

  Net-new: not present in Python ADK.
  """

  alias ADK.Workflow.Graph
  alias ADK.Workflow.Graph.Validator

  @doc """
  Add a node to the graph.
  Returns `{:ok, graph}` or `{:error, reason}`.
  """
  @spec add_node(Graph.t(), Graph.node_id(), any()) :: {:ok, Graph.t()} | {:error, String.t()}
  def add_node(%Graph{} = graph, id, node_def) do
    if Map.has_key?(graph.nodes, id) do
      {:error, "node #{inspect(id)} already exists"}
    else
      {:ok, %Graph{graph | nodes: Map.put(graph.nodes, id, node_def)}}
    end
  end

  @doc """
  Remove a node and all edges referencing it.
  Returns `{:ok, graph}` or `{:error, reason}`.
  """
  @spec remove_node(Graph.t(), Graph.node_id()) :: {:ok, Graph.t()} | {:error, String.t()}
  def remove_node(%Graph{} = graph, id) do
    if not Map.has_key?(graph.nodes, id) do
      {:error, "node #{inspect(id)} not found"}
    else
      new_nodes = Map.delete(graph.nodes, id)

      new_edges =
        graph.edges
        |> Enum.reject(fn
          {^id, _} -> true
          {_, ^id} -> true
          {_, %{} = routes} -> id in Map.values(routes)
          _ -> false
        end)

      {:ok, %Graph{graph | nodes: new_nodes, edges: new_edges}}
    end
  end

  @doc """
  Add an edge to the graph. Validates no cycles and no dangling references.
  """
  @spec add_edge(Graph.t(), Graph.edge()) :: {:ok, Graph.t()} | {:error, String.t()}
  def add_edge(%Graph{} = graph, edge) do
    new_graph = %Graph{graph | edges: graph.edges ++ [edge]}

    with :ok <- validate_edge_refs(new_graph, edge),
         true <- Validator.acyclic?(new_graph) || {:error, "adding edge would create a cycle"} do
      {:ok, new_graph}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Remove an edge from the graph.
  """
  @spec remove_edge(Graph.t(), Graph.node_id(), Graph.node_id()) ::
          {:ok, Graph.t()} | {:error, String.t()}
  def remove_edge(%Graph{} = graph, from, to) do
    {removed, kept} =
      Enum.split_with(graph.edges, fn
        {^from, ^to} -> true
        _ -> false
      end)

    if removed == [] do
      {:error, "edge {#{inspect(from)}, #{inspect(to)}} not found"}
    else
      {:ok, %Graph{graph | edges: kept}}
    end
  end

  @doc """
  Replace a node's definition, keeping all edges intact.
  """
  @spec replace_node(Graph.t(), Graph.node_id(), any()) ::
          {:ok, Graph.t()} | {:error, String.t()}
  def replace_node(%Graph{} = graph, id, new_def) do
    if not Map.has_key?(graph.nodes, id) do
      {:error, "node #{inspect(id)} not found"}
    else
      {:ok, %Graph{graph | nodes: Map.put(graph.nodes, id, new_def)}}
    end
  end

  @doc """
  Merge two graphs (union of nodes and edges).
  Nodes in `graph2` override those in `graph1` on conflict.
  Validates the merged result.
  """
  @spec merge(Graph.t(), Graph.t()) :: {:ok, Graph.t()} | {:error, String.t()}
  def merge(%Graph{} = g1, %Graph{} = g2) do
    merged = %Graph{
      nodes: Map.merge(g1.nodes, g2.nodes),
      edges: Enum.uniq(g1.edges ++ g2.edges)
    }

    if Validator.acyclic?(merged) do
      {:ok, merged}
    else
      {:error, "merged graph contains a cycle"}
    end
  end

  # ── Private ──

  defp validate_edge_refs(%Graph{nodes: nodes}, edge) do
    known = MapSet.new(Map.keys(nodes))

    refs = case edge do
      {from, %{} = routes} -> [from | Map.values(routes)]
      {from, to} -> [from, to]
    end

    missing = Enum.reject(refs, &MapSet.member?(known, &1))

    if missing == [],
      do: :ok,
      else: {:error, "dangling edge references: #{inspect(missing)}"}
  end
end
