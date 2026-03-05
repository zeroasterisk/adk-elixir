defmodule ADK.Agent.SequentialAgent do
  @moduledoc """
  Runs sub-agents in sequence, passing state through the session.
  """
  @behaviour ADK.Agent

  @doc """
  Create a sequential agent spec.

  ## Examples

      iex> agent = ADK.Agent.SequentialAgent.new(name: "pipeline", sub_agents: [])
      iex> agent.name
      "pipeline"
  """
  @spec new(keyword()) :: ADK.Agent.t()
  def new(opts) do
    %{
      name: opts[:name] || "sequential",
      description: opts[:description] || "Runs agents in sequence",
      module: __MODULE__,
      config: %{sub_agents: opts[:sub_agents] || []},
      sub_agents: opts[:sub_agents] || []
    }
  end

  @impl true
  def run(ctx) do
    ctx.agent.config.sub_agents
    |> Enum.flat_map(fn agent_spec ->
      child_ctx = ADK.Context.for_child(ctx, agent_spec)
      agent_spec.module.run(child_ctx)
    end)
  end
end
