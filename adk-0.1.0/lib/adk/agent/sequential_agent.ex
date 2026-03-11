defmodule ADK.Agent.SequentialAgent do
  @moduledoc """
  Runs sub-agents in sequence, passing state through the session.
  """

  @enforce_keys [:name]
  defstruct [:name, description: "Runs agents in sequence", sub_agents: []]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          sub_agents: [ADK.Agent.t()]
        }

  @doc """
  Create a sequential agent.

  ## Examples

      iex> agent = ADK.Agent.SequentialAgent.new(name: "pipeline", sub_agents: [])
      iex> agent.name
      "pipeline"
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Create a sequential agent with validation.

  Returns `{:ok, agent}` or `{:error, reason}`.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(opts) do
    {:ok, new(opts)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defimpl ADK.Agent do
    def name(agent), do: agent.name
    def description(agent), do: agent.description
    def sub_agents(agent), do: agent.sub_agents

    def run(agent, ctx) do
      agent.sub_agents
      |> Enum.flat_map(fn agent_spec ->
        child_ctx = ADK.Context.for_child(ctx, agent_spec)
        ADK.Agent.run(agent_spec, child_ctx)
      end)
    end
  end
end
