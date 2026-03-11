defmodule ADK.Agent.Custom do
  @moduledoc """
  A simple agent that wraps a function. Useful for testing and ad-hoc agents.

  ## Examples

      agent = ADK.Agent.Custom.new(
        name: "greeter",
        run_fn: fn _agent, _ctx -> [ADK.Event.new(%{author: "greeter", content: "hi"})] end
      )
  """

  @enforce_keys [:name, :run_fn]
  defstruct [:name, :run_fn, description: "", sub_agents: [], tools: []]

  @type t :: %__MODULE__{
          name: String.t(),
          run_fn: (t(), ADK.Context.t() -> [ADK.Event.t()]),
          description: String.t(),
          sub_agents: [ADK.Agent.t()],
          tools: [map()]
        }

  @doc "Create a custom agent."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  defimpl ADK.Agent do
    def name(agent), do: agent.name
    def description(agent), do: agent.description
    def sub_agents(agent), do: agent.sub_agents
    def run(agent, ctx), do: agent.run_fn.(agent, ctx)
  end
end
