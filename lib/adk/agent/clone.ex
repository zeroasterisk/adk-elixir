defmodule ADK.Agent.Clone do
  @moduledoc """
  Clone utility for ADK agent structs.

  Mirrors Python ADK's `BaseAgent.clone()`:
  - Deep copies sub_agents recursively
  - Shallow copies list fields (new list, same element references)
  - Resets parent_agent to nil on the cloned root
  - Wires parent_agent on cloned sub_agents to point at the new clone
  - Validates update keys exist on the struct
  - Disallows updating `parent_agent` directly
  """

  @doc """
  Clone an agent with optional field overrides.
  """
  @spec clone(struct(), map() | nil) :: struct()
  def clone(agent, update \\ nil)

  def clone(agent, nil), do: do_clone(agent, %{})
  def clone(agent, update) when update == %{}, do: do_clone(agent, %{})
  def clone(agent, update) when is_map(update), do: do_clone(agent, update)

  defp do_clone(_agent, %{parent_agent: _}) do
    raise ArgumentError, "Cannot update `parent_agent` field in clone"
  end

  defp do_clone(agent, update) do
    struct_fields = agent |> Map.from_struct() |> Map.keys()
    invalid_fields = update |> Map.keys() |> Enum.reject(&(&1 in struct_fields))

    if invalid_fields != [] do
      raise ArgumentError, "Cannot update nonexistent fields: #{inspect(invalid_fields)}"
    end

    sub_agents =
      Map.get_lazy(update, :sub_agents, fn ->
        Enum.map(agent.sub_agents || [], &clone(&1))
      end)

    base = Map.from_struct(agent)
    merged = Map.merge(base, update)
    merged = Map.put(merged, :parent_agent, nil)
    merged = Map.put(merged, :sub_agents, sub_agents)

    # Shallow-copy list fields
    merged =
      Enum.reduce(merged, merged, fn
        {:sub_agents, _}, acc -> acc
        {key, value}, acc when is_list(value) -> Map.put(acc, key, Enum.map(value, & &1))
        _, acc -> acc
      end)

    cloned = struct(agent.__struct__, merged)

    maybe_wire_parent(cloned, sub_agents)
  end

  defp maybe_wire_parent(cloned, []) do
    cloned
  end

  defp maybe_wire_parent(cloned, _sub_agents) do
    updated_subs =
      Enum.map(cloned.sub_agents, fn
        %{parent_agent: _} = sub -> %{sub | parent_agent: cloned}
        sub -> sub
      end)

    %{cloned | sub_agents: updated_subs}
  end
end
