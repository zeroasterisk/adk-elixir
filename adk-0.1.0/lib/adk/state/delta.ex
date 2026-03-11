defmodule ADK.State.Delta do
  @moduledoc "Immutable snapshot + diff for state delta tracking."

  @type t :: %{added: map(), changed: map(), removed: [term()]}

  @doc """
  Compute the difference between two state maps.

  ## Examples

      iex> ADK.State.Delta.diff(%{a: 1, b: 2}, %{a: 1, b: 3, c: 4})
      %{added: %{c: 4}, changed: %{b: 3}, removed: []}

      iex> ADK.State.Delta.diff(%{a: 1, b: 2}, %{a: 1})
      %{added: %{}, changed: %{}, removed: [:b]}

      iex> ADK.State.Delta.diff(%{}, %{x: 1})
      %{added: %{x: 1}, changed: %{}, removed: []}
  """
  @spec diff(map(), map()) :: t()
  def diff(old, new) do
    old_keys = Map.keys(old) |> MapSet.new()
    new_keys = Map.keys(new) |> MapSet.new()

    added_keys = MapSet.difference(new_keys, old_keys)
    removed_keys = MapSet.difference(old_keys, new_keys)
    common_keys = MapSet.intersection(old_keys, new_keys)

    added = Map.take(new, MapSet.to_list(added_keys))
    removed = MapSet.to_list(removed_keys)

    changed =
      common_keys
      |> Enum.filter(fn k -> Map.get(old, k) != Map.get(new, k) end)
      |> Map.new(fn k -> {k, Map.get(new, k)} end)

    %{added: added, changed: changed, removed: removed}
  end

  @doc """
  Apply a delta to a state map.

  ## Examples

      iex> delta = %{added: %{c: 3}, changed: %{a: 10}, removed: [:b]}
      iex> ADK.State.Delta.apply_delta(%{a: 1, b: 2}, delta)
      %{a: 10, c: 3}
  """
  @spec apply_delta(map(), t()) :: map()
  def apply_delta(state, %{added: a, changed: c, removed: r}) do
    state
    |> Map.merge(a)
    |> Map.merge(c)
    |> Map.drop(r)
  end
end
