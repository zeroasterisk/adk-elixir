defprotocol ADK.Agent do
  @moduledoc """
  The core agent protocol. Every agent type implements this.

  Each agent is a struct with at minimum a `name` field. The protocol
  provides polymorphic dispatch for running agents and accessing metadata.

  ## Implementing a custom agent

      defmodule MyAgent do
        @enforce_keys [:name]
        defstruct [:name, description: "", sub_agents: []]

        defimpl ADK.Agent do
          def name(agent), do: agent.name
          def description(agent), do: agent.description
          def sub_agents(agent), do: agent.sub_agents
          def run(agent, ctx), do: [ADK.Event.new(%{author: agent.name, content: "hello"})]
        end
      end
  """

  @doc "Agent name identifier."
  @spec name(t()) :: String.t()
  def name(agent)

  @doc "Human-readable description."
  @spec description(t()) :: String.t()
  def description(agent)

  @doc "Child agents for delegation."
  @spec sub_agents(t()) :: [t()]
  def sub_agents(agent)

  @doc "Execute the agent, returning a list of events."
  @spec run(t(), ADK.Context.t()) :: [ADK.Event.t()]
  def run(agent, ctx)
end
