defmodule ADK.InstructionCompiler do
  @moduledoc """
  Compiles the system instruction for an LLM agent by combining:

  - Global instruction (from agent or parent)
  - Agent's own instruction (with template variable substitution from state)
  - Identity/persona instruction
  - Output schema instruction
  - Transfer instructions (listing available sub-agents)

  This mirrors Python ADK's `BaseLlmFlow._compile_system_instruction()`.
  """

  @doc """
  Compile the full system instruction for an agent given the context.

  Returns a single string combining all instruction components.
  """
  @spec compile(map(), ADK.Context.t()) :: String.t()
  def compile(agent, ctx) do
    [
      global_instruction(agent),
      identity_instruction(agent),
      agent_instruction(agent, ctx),
      output_schema_instruction(agent),
      transfer_instruction(agent)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Substitute template variables in an instruction string.

  Variables use the `{key}` syntax. Values are looked up from session state.

  ## Examples

      iex> ADK.InstructionCompiler.substitute_vars("Hello {name}!", %{"name" => "World"})
      "Hello World!"

      iex> ADK.InstructionCompiler.substitute_vars("No vars here", %{})
      "No vars here"
  """
  @spec substitute_vars(String.t(), map()) :: String.t()
  def substitute_vars(instruction, state) when is_binary(instruction) and is_map(state) do
    Regex.replace(~r/\{(\w+)\}/, instruction, fn full_match, key ->
      atom_value =
        try do
          Map.get(state, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end

      case Map.get(state, key) || atom_value do
        nil -> full_match
        value -> to_string(value)
      end
    end)
  end

  def substitute_vars(instruction, _state), do: instruction

  # --- Private helpers ---

  defp global_instruction(agent) do
    Map.get(agent, :global_instruction, nil)
  end

  defp identity_instruction(agent) do
    name = Map.get(agent, :name, nil)
    description = Map.get(agent, :description, nil)

    cond do
      name && description && description != "" ->
        "You are #{name}. #{description}"

      name ->
        "You are #{name}."

      true ->
        nil
    end
  end

  defp agent_instruction(agent, ctx) do
    case Map.get(agent, :instruction, nil) do
      nil ->
        nil

      instruction when is_binary(instruction) ->
        state = get_session_state(ctx)
        substitute_vars(instruction, state)

      instruction when is_function(instruction, 1) ->
        instruction.(ctx)
    end
  end

  defp output_schema_instruction(agent) do
    case Map.get(agent, :output_schema, nil) do
      nil ->
        nil

      schema when is_map(schema) ->
        "Reply with valid JSON matching this schema: #{Jason.encode!(schema)}"
    end
  end

  defp transfer_instruction(agent) do
    sub_agents = Map.get(agent, :sub_agents, [])

    if sub_agents == [] do
      nil
    else
      agent_descriptions =
        Enum.map_join(sub_agents, "\n", fn sa ->
          name = ADK.Agent.name(sa)
          desc = ADK.Agent.description(sa)

          if desc && desc != "" do
            "- #{name}: #{desc}"
          else
            "- #{name}"
          end
        end)

      """
      You can delegate tasks to the following agents using the transfer_to_agent tool:
      #{agent_descriptions}

      To transfer to an agent, call the transfer_to_agent tool with the agent's name.\
      """
    end
  end

  defp get_session_state(ctx) do
    if ctx.session_pid do
      try do
        ADK.Session.get_all_state(ctx.session_pid)
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end
    else
      %{}
    end
  end
end
