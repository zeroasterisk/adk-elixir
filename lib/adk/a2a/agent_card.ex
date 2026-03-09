defmodule ADK.A2A.AgentCard do
  @moduledoc """
  Generates an A2A Agent Card from an ADK agent.

  The Agent Card is served at `/.well-known/agent.json` and describes
  the agent's capabilities, skills, and endpoint URL.

  This module bridges ADK agents to the `A2A.AgentCard` protocol type
  from the [a2a](https://github.com/zeroasterisk/a2a-elixir) package.
  """

  @doc """
  Generate an A2A Agent Card map from an ADK agent.

  ## Options
    - `:url` — the agent's A2A endpoint URL (required)
    - `:version` — agent version (default "1.0.0")
    - `:provider` — provider info map

  ## Examples

      iex> agent = ADK.Agent.LlmAgent.new(name: "helper", model: "test", instruction: "Help", description: "A helpful agent", tools: [])
      iex> card = ADK.A2A.AgentCard.from_agent(agent, url: "http://localhost:4000/a2a")
      iex> card["name"]
      "helper"
  """
  @spec from_agent(ADK.Agent.t(), keyword()) :: map()
  def from_agent(agent, opts \\ []) do
    url = Keyword.fetch!(opts, :url)

    to_a2a_card(agent, opts)
    |> A2A.AgentCard.to_map()
    |> Map.put("url", url)
  end

  @doc """
  Build an `A2A.AgentCard` struct from an ADK agent.
  """
  @spec to_a2a_card(ADK.Agent.t(), keyword()) :: A2A.AgentCard.t()
  def to_a2a_card(agent, opts \\ []) do
    A2A.AgentCard.new(
      name: ADK.Agent.name(agent),
      url: Keyword.get(opts, :url, "http://localhost:4000"),
      description: ADK.Agent.description(agent),
      version: Keyword.get(opts, :version, "1.0.0"),
      provider: opts[:provider],
      skills: build_skills(agent)
    )
  end

  defp build_skills(%ADK.Agent.LlmAgent{tools: tools}) when is_list(tools) and tools != [] do
    Enum.map(tools, &tool_to_skill/1)
  end

  defp build_skills(_), do: []

  defp tool_to_skill(%{name: name, description: desc}) do
    %{id: to_string(name), name: to_string(name), description: desc || ""}
  end

  defp tool_to_skill(%ADK.Tool.FunctionTool{name: name, description: desc}) do
    %{id: to_string(name), name: to_string(name), description: desc || ""}
  end

  defp tool_to_skill(mod) when is_atom(mod) do
    %{id: mod.name(), name: mod.name(), description: mod.description()}
  end

  defp tool_to_skill(_), do: %{id: "unknown", name: "unknown", description: ""}
end
