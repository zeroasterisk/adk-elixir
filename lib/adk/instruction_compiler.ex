defmodule ADK.InstructionCompiler do
  @moduledoc """
  Compiles the system instruction for an LLM agent by combining:

  - Global instruction (from agent or parent)
  - Agent's own instruction (with template variable substitution from state)
  - Identity/persona instruction
  - Output schema instruction
  - Transfer instructions (listing available sub-agents)

  This mirrors Python ADK's `BaseLlmFlow._compile_system_instruction()`.

  ## InstructionProvider

  Both the `instruction` and `global_instruction` fields on `ADK.Agent.LlmAgent`
  support dynamic providers in addition to static strings:

  - `String.t()` — static instruction (existing behaviour, unchanged)
  - `(ADK.Context.t() -> String.t())` — 1-arity anonymous function called at runtime
  - `{module, atom}` — MFA with 1 arg (context appended): `module.atom(ctx)`
  - `{module, atom, extra_args}` — MFA with extra args (context prepended): `module.atom(ctx, extra_args...)`

  The provider is called once per invocation, just before template-variable
  substitution, so the returned string still supports `{variable}` interpolation.

  If a provider returns a non-binary value, it is coerced via `to_string/1`.
  If the provider raises, the error is logged and an empty string is used so
  the agent can still respond.
  """

  @doc """
  Compile the full system instruction for an agent given the context.

  Returns a single string combining all instruction components.
  """
  @spec compile(map(), ADK.Context.t()) :: String.t()
  def compile(agent, ctx) do
    {static, dynamic} = compile_split(agent, ctx)

    [static, dynamic]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Split compiled instructions into static and dynamic portions.

  - **Static**: Parts that don't change between requests — global instruction,
    identity, transfer instructions. Suitable for Gemini's context caching.
  - **Dynamic**: Parts that change per request — agent instruction with state
    variable substitution, output schema instruction.

  Returns `{static_instruction, dynamic_instruction}` where either may be an
  empty string (but never nil).
  """
  @spec compile_split(map(), ADK.Context.t()) :: {String.t(), String.t()}
  def compile_split(agent, ctx) do
    static_parts =
      [
        global_instruction(agent, ctx),
        identity_instruction(agent),
        transfer_instruction(agent)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))

    dynamic_parts =
      [
        agent_instruction(agent, ctx),
        output_schema_instruction(agent)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))

    {Enum.join(static_parts, "\n\n"), Enum.join(dynamic_parts, "\n\n")}
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

  defp global_instruction(agent, ctx) do
    # global_instruction supports static strings AND dynamic providers
    case Map.get(agent, :global_instruction, nil) do
      nil ->
        nil

      provider when is_binary(provider) ->
        state = get_session_state(ctx)
        substitute_vars(provider, state)

      provider ->
        resolved = resolve_provider(provider, ctx)

        if is_binary(resolved) do
          state = get_session_state(ctx)
          substitute_vars(resolved, state)
        else
          resolved
        end
    end
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

      provider ->
        # Dynamic provider: resolve then apply template vars
        resolved = resolve_provider(provider, ctx)

        if is_binary(resolved) do
          state = get_session_state(ctx)
          substitute_vars(resolved, state)
        else
          resolved
        end
    end
  end

  @doc """
  Resolve an instruction provider to a string.

  Handles:
  - `String.t()` — returned as-is
  - `(ctx -> String.t())` — called with the context (may be nil for global)
  - `{module, atom}` — called as `module.atom(ctx)`
  - `{module, atom, extra_args}` — called as `module.atom(ctx, extra_args...)`

  Non-binary return values are coerced via `to_string/1`. Errors are caught
  and an empty string is returned (with a warning logged).
  """
  @spec resolve_provider(term(), ADK.Context.t() | nil) :: String.t() | nil
  def resolve_provider(nil, _ctx), do: nil

  def resolve_provider(instruction, _ctx) when is_binary(instruction), do: instruction

  def resolve_provider(fun, ctx) when is_function(fun, 1) do
    safe_call(fn -> fun.(ctx) end)
  end

  def resolve_provider({mod, fun_name}, ctx)
      when is_atom(mod) and is_atom(fun_name) do
    safe_call(fn -> apply(mod, fun_name, [ctx]) end)
  end

  def resolve_provider({mod, fun_name, extra_args}, ctx)
      when is_atom(mod) and is_atom(fun_name) and is_list(extra_args) do
    safe_call(fn -> apply(mod, fun_name, [ctx | extra_args]) end)
  end

  def resolve_provider(other, _ctx) do
    require Logger
    Logger.warning("ADK.InstructionCompiler: unexpected instruction provider type: #{inspect(other)}")
    nil
  end

  defp safe_call(fun) do
    result = fun.()

    if is_binary(result) do
      result
    else
      to_string(result)
    end
  rescue
    e ->
      require Logger
      Logger.warning("ADK.InstructionCompiler: instruction provider raised: #{Exception.message(e)}")
      ""
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
