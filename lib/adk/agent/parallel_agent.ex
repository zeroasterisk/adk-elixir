defmodule ADK.Agent.ParallelAgent do
  @moduledoc """
  Runs sub-agents concurrently using `Task.async_stream`, collecting all events.

  ## Examples

      agent = ADK.Agent.ParallelAgent.new(
        name: "fan_out",
        sub_agents: [research_agent, analysis_agent, summary_agent]
      )
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    :parent_agent,
    description: "Runs agents in parallel",
    sub_agents: [],
    timeout: 30_000
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          sub_agents: [ADK.Agent.t()],
          timeout: pos_integer()
        }

  @doc """
  Create a parallel agent.

  ## Examples

      iex> agent = ADK.Agent.ParallelAgent.new(name: "fan_out", sub_agents: [])
      iex> agent.name
      "fan_out"
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Create a parallel agent with validation.

  Returns `{:ok, agent}` or `{:error, reason}`.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(opts) do
    {:ok, new(opts)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  @doc "Clone this agent with optional updates. See `ADK.Agent.Clone`."
  @spec clone(t(), map() | nil) :: t()
  def clone(agent, update \\ nil), do: ADK.Agent.Clone.clone(agent, update)

  defimpl ADK.Agent do
    def name(agent), do: agent.name
    def description(agent), do: agent.description
    def sub_agents(agent), do: agent.sub_agents

    def run(agent, ctx) do
      sub_agents = agent.sub_agents
      sub_agents
      |> Task.async_stream(
        fn agent_spec ->
          child_ctx = ADK.Context.for_child(ctx, agent_spec)
          ADK.Agent.run(agent_spec, child_ctx)
        end,
        timeout: agent.timeout,
        ordered: true
      )
      |> Enum.flat_map(fn
        {:ok, events} ->
          events

        {:exit, reason} ->
          [ADK.Event.new(author: "parallel", content: "Agent failed: #{inspect(reason)}")]
      end)
    end
  end
end
