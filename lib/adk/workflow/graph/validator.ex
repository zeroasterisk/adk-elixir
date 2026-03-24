defmodule ADK.Workflow.Graph.Validator do
  @moduledoc """
  Validates workflow graph structure.

  Net-new: not present in Python ADK.
  """

  alias ADK.Workflow.Graph

  @doc """
  Validate the graph structure.

  Checks:
  - No cycles (DAG enforcement)
  - All edge targets reference known nodes
  - `:START` node exists with outgoing edges
  - `:END` is reachable from `:START`
  - No orphan nodes (unreachable from `:START`)

  Returns `:ok` or `{:error, reasons}` where reasons is a list of strings.
  """
  @spec validate(Graph.t()) :: :ok | {:error, [String.t()]}
  def validate(%Graph{} = graph) do
    checks = [
      &check_start/1,
      &check_references/1,
      &check_acyclic/1,
      &check_end_reachable/1,
      &check_no_orphans/1
    ]

    errors =
      Enum.flat_map(checks, fn check ->
        case check.(graph) do
          :ok -> []
          {:error, reason} when is_binary(reason) -> [reason]
          {:error, reasons} when is_list(reasons) -> reasons
        end
      end)

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  @doc """
  Returns `true` if the graph has no cycles.
  Uses DFS-based cycle detection.
  """
  @spec acyclic?(Graph.t()) :: boolean()
  def acyclic?(%Graph{} = graph) do
    not has_cycle?(graph)
  end

  # ── Private ──

  defp check_start(%Graph{edges: edges}) do
    has_start = Enum.any?(edges, fn
      {:START, _} -> true
      _ -> false
    end)

    if has_start, do: :ok, else: {:error, "graph must have :START with outgoing edges"}
  end

  defp check_references(%Graph{nodes: nodes, edges: edges}) do
    known = MapSet.new(Map.keys(nodes))

    missing =
      edges
      |> Enum.flat_map(fn
        {from, %{} = routes} -> [from | Map.values(routes)]
        {from, to} -> [from, to]
      end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known, &1))

    if missing == [],
      do: :ok,
      else: {:error, "unknown nodes in edges: #{inspect(missing)}"}
  end

  defp check_acyclic(graph) do
    if acyclic?(graph), do: :ok, else: {:error, "graph contains a cycle"}
  end

  defp check_end_reachable(graph) do
    reachable = reachable_from(graph, :START)

    if MapSet.member?(reachable, :END),
      do: :ok,
      else: {:error, ":END is not reachable from :START"}
  end

  defp check_no_orphans(%Graph{nodes: nodes} = graph) do
    reachable = reachable_from(graph, :START)
    all = MapSet.new(Map.keys(nodes))
    orphans = MapSet.difference(all, reachable) |> MapSet.delete(:START) |> MapSet.to_list()

    if orphans == [],
      do: :ok,
      else: {:error, "orphan nodes: #{inspect(orphans)}"}
  end

  defp reachable_from(graph, start) do
    bfs(graph, [start], MapSet.new())
  end

  defp bfs(_graph, [], visited), do: visited

  defp bfs(graph, [node | rest], visited) do
    if MapSet.member?(visited, node) do
      bfs(graph, rest, visited)
    else
      visited = MapSet.put(visited, node)
      succs = Graph.successors(graph, node)
      bfs(graph, rest ++ succs, visited)
    end
  end

  defp has_cycle?(%Graph{nodes: nodes} = graph) do
    node_ids = Map.keys(nodes)

    Enum.reduce_while(node_ids, {MapSet.new(), false}, fn node, {visited, _} ->
      if MapSet.member?(visited, node) do
        {:cont, {visited, false}}
      else
        case dfs_cycle(graph, node, visited, MapSet.new()) do
          {:cycle, _} -> {:halt, {visited, true}}
          {:ok, new_visited} -> {:cont, {new_visited, false}}
        end
      end
    end)
    |> elem(1)
  end

  defp dfs_cycle(graph, node, visited, stack) do
    cond do
      MapSet.member?(stack, node) -> {:cycle, node}
      MapSet.member?(visited, node) -> {:ok, visited}
      true ->
        stack = MapSet.put(stack, node)
        visited = MapSet.put(visited, node)

        Graph.successors(graph, node)
        |> Enum.reduce_while({:ok, visited}, fn succ, {:ok, v} ->
          case dfs_cycle(graph, succ, v, stack) do
            {:cycle, _} = c -> {:halt, c}
            {:ok, v2} -> {:cont, {:ok, v2}}
          end
        end)
    end
  end
end
