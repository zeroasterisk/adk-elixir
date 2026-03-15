defmodule ADK.Yaml do
  @moduledoc """
  Provides functions to load `ADK.Agent` (and other configurations) from YAML.
  """

  @doc """
  Loads an agent configuration from a YAML file.

  ## Examples

      {:ok, agent} = ADK.Yaml.load_agent_file("agent.yaml")

  """
  def load_agent_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} -> parse_agent(data)
      {:error, reason} -> {:error, "Failed to read YAML file: #{inspect(reason)}"}
    end
  end

  @doc """
  Loads an agent configuration from a YAML file, raising on error.
  """
  def load_agent_file!(path) do
    case load_agent_file(path) do
      {:ok, agent} -> agent
      {:error, reason} -> raise ArgumentError, "YAML file parsing failed: #{inspect(reason)}"
    end
  end

  @doc """
  Loads an agent configuration from a YAML string.

  ## Examples

      yaml = \"\"\"
      name: my_agent
      model: gemini-2.5-flash
      instruction: You are a helpful assistant.
      \"\"\"
      {:ok, agent} = ADK.Yaml.load_agent(yaml)

  """
  def load_agent(yaml_string) when is_binary(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, data} -> parse_agent(data)
      {:error, %YamlElixir.ParsingError{} = err} -> {:error, Exception.message(err)}
      {:error, reason} -> {:error, "Failed to parse YAML string: #{inspect(reason)}"}
    end
  end

  @doc """
  Loads an agent configuration from a YAML string, raising on error.
  """
  def load_agent!(yaml_string) do
    case load_agent(yaml_string) do
      {:ok, agent} -> agent
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp parse_agent(data) when is_map(data) do
    name = data["name"] || "yaml_agent"
    model = data["model"] || "gemini-2.5-flash"
    instruction = data["instruction"] || ""
    global_instruction = data["global_instruction"]
    description = data["description"] || ""
    output_key = if data["output_key"], do: String.to_atom(data["output_key"]), else: nil
    max_iterations = data["max_iterations"] || 10
    disallow_transfer_to_parent = Map.get(data, "disallow_transfer_to_parent", false)
    disallow_transfer_to_peers = Map.get(data, "disallow_transfer_to_peers", false)
    tools = parse_tools(data["tools"])
    sub_agents = parse_sub_agents(data["sub_agents"])

    opts = [
      name: name,
      model: model,
      instruction: instruction,
      description: description,
      tools: tools,
      sub_agents: sub_agents,
      max_iterations: max_iterations,
      disallow_transfer_to_parent: disallow_transfer_to_parent,
      disallow_transfer_to_peers: disallow_transfer_to_peers
    ]

    opts = if global_instruction, do: Keyword.put(opts, :global_instruction, global_instruction), else: opts
    opts = if output_key, do: Keyword.put(opts, :output_key, output_key), else: opts

    ADK.Agent.LlmAgent.build(opts)
  end

  defp parse_agent(_), do: {:error, "YAML root must be a map/dictionary"}

  defp parse_sub_agents(nil), do: []
  defp parse_sub_agents(agents) when is_list(agents) do
    Enum.map(agents, fn
      agent_map when is_map(agent_map) ->
        case parse_agent(agent_map) do
          {:ok, agent} -> agent
          _ -> agent_map
        end
      other -> other
    end)
  end
  defp parse_sub_agents(_), do: []

  defp parse_tools(nil), do: []
  defp parse_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      tool_name when is_binary(tool_name) ->
        %{name: tool_name, description: "Tool loaded from yaml config"}
      tool_map when is_map(tool_map) ->
        tool_map
        |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
        |> Map.new()
      other -> other
    end)
  end
  defp parse_tools(_), do: []
end
