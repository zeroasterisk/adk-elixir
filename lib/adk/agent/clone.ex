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

  defp do_clone(agent, update) do
    if Map.has_key?(update, :parent_agent) do
      raise ArgumentError, "Cannot update `parent_agent` field in clone"
    end

    struct_fields = agent |> Map.from_struct() |> Map.keys()
    invalid_fields = update |> Map.keys() |> Enum.reject(&(&1 in struct_fields))

    if invalid_fields != [] do
      raise ArgumentError, "Cannot update nonexistent fields: #{inspect(invalid_fields)}"
    end

    sub_agents =
      if Map.has_key?(update, :sub_agents) do
        update[:sub_agents]
      else
        Enum.map(agent.sub_agents || [], &clone(&1))
      end

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

    if sub_agents != [] do
      updated_subs =
        Enum.map(cloned.sub_agents, fn sub ->
          if Map.has_key?(sub, :parent_agent) do
            %{sub | parent_agent: cloned}
          else
            sub
          end
        end)

      %{cloned | sub_agents: updated_subs}
    else
      cloned
    end
  end
end
