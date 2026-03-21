defmodule ADK.AgentConfig do
  @moduledoc """
  Load agent configurations from YAML files or strings.

  Supports a discriminator field `agent_class` to determine the agent type:
  - `"LlmAgent"` (default when omitted)
  - `"LoopAgent"`
  - `"ParallelAgent"`
  - `"SequentialAgent"`

  Sub-agents can be defined inline or via `config_path` references resolved
  relative to the parent config file.

  ## Examples

      {:ok, agent} = ADK.AgentConfig.from_config("path/to/agent.yaml")

      {:ok, agent} = ADK.AgentConfig.from_yaml(\"""
      name: my_agent
      model: gemini-2.0-flash
      instruction: Be helpful.
      \""")
  """

  @agent_class_map %{
    "LlmAgent" => :llm,
    "LoopAgent" => :loop,
    "ParallelAgent" => :parallel,
    "SequentialAgent" => :sequential
  }

  @doc """
  Load an agent from a YAML config file.

  Sub-agent `config_path` references are resolved relative to the directory
  containing the config file.
  """
  @spec from_config(String.t()) :: {:ok, struct()} | {:error, term()}
  def from_config(path) do
    path = Path.expand(path)

    case YamlElixir.read_from_file(path) do
      {:ok, data} -> build_agent(data, Path.dirname(path))
      {:error, reason} -> {:error, "Failed to read YAML file: #{inspect(reason)}"}
    end
  end

  @doc "Same as `from_config/1` but raises on error."
  @spec from_config!(String.t()) :: struct()
  def from_config!(path) do
    case from_config(path) do
      {:ok, agent} -> agent
      {:error, reason} -> raise ArgumentError, "AgentConfig load failed: #{inspect(reason)}"
    end
  end

  @doc """
  Load an agent from a YAML string.

  Since there is no file context, `config_path` sub-agent references
  are resolved relative to the current working directory.
  """
  @spec from_yaml(String.t()) :: {:ok, struct()} | {:error, term()}
  def from_yaml(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, data} -> build_agent(data, File.cwd!())
      {:error, reason} -> {:error, "Failed to parse YAML: #{inspect(reason)}"}
    end
  end

  @doc "Same as `from_yaml/1` but raises on error."
  @spec from_yaml!(String.t()) :: struct()
  def from_yaml!(yaml_string) do
    case from_yaml(yaml_string) do
      {:ok, agent} -> agent
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Returns the parsed config map with the resolved `agent_class`.

  Useful for inspecting the discriminator before building an agent.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, data} -> {:ok, normalize_config(data)}
      {:error, reason} -> {:error, "Failed to parse YAML: #{inspect(reason)}"}
    end
  end

  # --- Internal ---

  defp build_agent(data, base_dir) when is_map(data) do
    config = normalize_config(data)
    agent_type = resolve_agent_type(config["agent_class"])

    case agent_type do
      :llm -> build_llm_agent(config, base_dir)
      :loop -> build_composite_agent(ADK.Agent.LoopAgent, config, base_dir)
      :parallel -> build_composite_agent(ADK.Agent.ParallelAgent, config, base_dir)
      :sequential -> build_composite_agent(ADK.Agent.SequentialAgent, config, base_dir)
      :unknown -> {:error, "Unknown agent_class: #{config["agent_class"]}"}
    end
  end

  defp build_agent(_, _), do: {:error, "YAML root must be a map"}

  defp normalize_config(data) do
    # Default agent_class to "LlmAgent" when not specified
    Map.put_new(data, "agent_class", "LlmAgent")
  end

  defp resolve_agent_type(agent_class) when is_binary(agent_class) do
    # Extract the short class name from potentially qualified paths like
    # "google.adk.agents.llm_agent.LlmAgent" or "google.adk.agents.LlmAgent"
    short_name =
      agent_class
      |> String.split(".")
      |> List.last()

    Map.get(@agent_class_map, short_name, :unknown)
  end

  defp resolve_agent_type(_), do: :llm

  defp build_llm_agent(config, base_dir) do
    model = resolve_model(config)
    sub_agents = resolve_sub_agents(config["sub_agents"], base_dir)

    opts =
      [
        name: config["name"] || "yaml_agent",
        model: model,
        instruction: config["instruction"] || "",
        description: config["description"] || "",
        sub_agents: sub_agents
      ]
      |> maybe_put(:global_instruction, config["global_instruction"])
      |> maybe_put(:output_key, atomize(config["output_key"]))
      |> maybe_put(:max_iterations, config["max_iterations"])

    {:ok, ADK.Agent.LlmAgent.new(opts)}
  end

  defp build_composite_agent(module, config, base_dir) do
    sub_agents = resolve_sub_agents(config["sub_agents"], base_dir)

    opts = [
      name: config["name"] || "yaml_agent",
      description: config["description"] || "",
      sub_agents: sub_agents
    ]

    {:ok, module.new(opts)}
  end

  defp resolve_model(config) do
    # model_code takes priority, then model (which can be a map for legacy LiteLlm)
    cond do
      is_map(config["model_code"]) ->
        build_model_code(config["model_code"])

      is_map(config["model"]) ->
        build_model_code(config["model"])

      is_binary(config["model"]) ->
        config["model"]

      true ->
        "gemini-2.0-flash"
    end
  end

  defp build_model_code(%{"args" => args} = model_code) when is_list(args) do
    # Convert [{name: k, value: v}, ...] to a map
    args_map =
      Enum.reduce(args, %{}, fn
        %{"name" => k, "value" => v}, acc -> Map.put(acc, k, v)
        _, acc -> acc
      end)

    %{
      name: model_code["name"],
      model: args_map["model"],
      args: Map.drop(args_map, ["model"])
    }
  end

  defp build_model_code(model_code) when is_map(model_code) do
    %{name: model_code["name"]}
  end

  defp resolve_sub_agents(nil, _base_dir), do: []
  defp resolve_sub_agents([], _base_dir), do: []

  defp resolve_sub_agents(agents, base_dir) when is_list(agents) do
    Enum.map(agents, fn
      %{"config_path" => rel_path} ->
        full_path = Path.join(base_dir, rel_path)

        case from_config(full_path) do
          {:ok, agent} -> agent
          {:error, reason} -> raise ArgumentError, "Failed to load sub-agent at #{full_path}: #{inspect(reason)}"
        end

      agent_map when is_map(agent_map) ->
        case build_agent(agent_map, base_dir) do
          {:ok, agent} -> agent
          {:error, reason} -> raise ArgumentError, "Failed to build inline sub-agent: #{inspect(reason)}"
        end
    end)
  end

  defp resolve_sub_agents(_, _base_dir), do: []

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp atomize(nil), do: nil
  defp atomize(s) when is_binary(s), do: String.to_atom(s)
  defp atomize(a) when is_atom(a), do: a
end
