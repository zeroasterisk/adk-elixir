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
  @behaviour ADK.Agent

  @default_max_iterations 10

  @doc """
  Create a loop agent spec.

  ## Options

    * `:name` - agent name (default: `"loop"`)
    * `:description` - agent description
    * `:sub_agents` - list of agent specs to run each iteration
    * `:max_iterations` - maximum loop count (default: #{@default_max_iterations})

  ## Examples

      iex> agent = ADK.Agent.LoopAgent.new(name: "loop", sub_agents: [], max_iterations: 3)
      iex> agent.config.max_iterations
      3
  """
  @spec new(keyword()) :: ADK.Agent.t()
  def new(opts) do
    %{
      name: opts[:name] || "loop",
      description: opts[:description] || "Runs agents in a loop",
      module: __MODULE__,
      config: %{
        sub_agents: opts[:sub_agents] || [],
        max_iterations: opts[:max_iterations] || @default_max_iterations
      },
      sub_agents: opts[:sub_agents] || []
    }
  end

  @impl true
  def run(ctx) do
    max = ctx.agent.config.max_iterations
    sub_agents = ctx.agent.config.sub_agents
    do_loop(ctx, sub_agents, max, 0, [])
  end

  defp do_loop(_ctx, _sub_agents, max, iteration, acc) when iteration >= max, do: acc

  defp do_loop(ctx, sub_agents, max, iteration, acc) do
    {events, escalated?} =
      Enum.reduce_while(sub_agents, {[], false}, fn agent_spec, {evts, _} ->
        child_ctx = ADK.Context.for_child(ctx, agent_spec)
        new_events = agent_spec.module.run(child_ctx)

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
