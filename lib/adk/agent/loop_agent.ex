defmodule ADK.Agent.LoopAgent do
  @moduledoc """
  Runs sub-agents in a loop until a maximum number of iterations is reached
  or an agent signals escalation via `EventActions.escalate`.

  ## Examples

      agent = ADK.Agent.LoopAgent.new(
        name: "retry_loop",
        sub_agents: [checker, fixer],
        max_iterations: 5
      )
  """

  @enforce_keys [:name]
  defstruct [:name, description: "Runs agents in a loop", sub_agents: [], max_iterations: 10]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          sub_agents: [ADK.Agent.t()],
          max_iterations: pos_integer()
        }

  @doc """
  Create a loop agent.

  ## Examples

      iex> agent = ADK.Agent.LoopAgent.new(name: "loop", sub_agents: [], max_iterations: 3)
      iex> agent.max_iterations
      3
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Create a loop agent with validation.

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
      ADK.Agent.LoopAgent.do_loop(ctx, agent.sub_agents, agent.max_iterations, 0, [])
    end
  end

  @doc false
  def do_loop(_ctx, _sub_agents, max, iteration, acc) when iteration >= max, do: acc

  def do_loop(ctx, sub_agents, max, iteration, acc) do
    {events, escalated?} =
      Enum.reduce_while(sub_agents, {[], false}, fn agent_spec, {evts, _} ->
        child_ctx = ADK.Context.for_child(ctx, agent_spec)
        new_events = ADK.Agent.run(agent_spec, child_ctx)

        if Enum.any?(new_events, &escalated?/1) do
          {:halt, {evts ++ new_events, true}}
        else
          {:cont, {evts ++ new_events, false}}
        end
      end)

    new_acc = acc ++ events

    if escalated? do
      new_acc
    else
      do_loop(ctx, sub_agents, max, iteration + 1, new_acc)
    end
  end

  defp escalated?(%{actions: %{escalate: true}}), do: true
  defp escalated?(%{actions: actions}) when is_map(actions), do: Map.get(actions, :escalate, false)
  defp escalated?(_), do: false
end
