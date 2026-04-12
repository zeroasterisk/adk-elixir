defmodule ADK.Agent.LoopAgent do
  @moduledoc """
  Runs sub-agents in a loop until a maximum number of iterations is reached,
  an exit_condition returns true, or an agent signals escalation via `EventActions.escalate`.

  ## Examples

      agent = ADK.Agent.LoopAgent.new(
        name: "retry_loop",
        sub_agents: [checker, fixer],
        max_iterations: 5
      )

      # With exit condition
      agent = ADK.Agent.LoopAgent.new(
        name: "until_done",
        sub_agents: [worker],
        max_iterations: 20,
        exit_condition: fn ctx -> ADK.Context.get_temp(ctx, :done) == true end
      )
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    :exit_condition,
    :parent_agent,
    description: "Runs agents in a loop",
    sub_agents: [],
    max_iterations: 10
  ]

  @type exit_condition :: (ADK.Context.t() -> boolean()) | nil

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          sub_agents: [ADK.Agent.t()],
          max_iterations: pos_integer(),
          exit_condition: exit_condition()
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

  @doc "Clone this agent with optional updates. See `ADK.Agent.Clone`."
  @spec clone(t(), map() | nil) :: t()
  def clone(agent, update \\ nil), do: ADK.Agent.Clone.clone(agent, update)

  defimpl ADK.Agent do
    def name(agent), do: agent.name
    def description(agent), do: agent.description
    def sub_agents(agent), do: agent.sub_agents

    def run(agent, ctx) do
      ADK.Agent.LoopAgent.do_loop(ctx, agent, {0, []})
    end
  end

  @doc false
  def do_loop(_ctx, %{max_iterations: max}, {iteration, acc}) when iteration >= max do
    finalize_events(acc)
  end

  def do_loop(
        ctx,
        %{sub_agents: sub_agents, exit_condition: exit_condition} = agent,
        {iteration, acc}
      ) do
    {events_acc, escalated?, updated_ctx} =
      Enum.reduce_while(sub_agents, {[], false, ctx}, fn agent_spec, {evts, _, cur_ctx} ->
        child_ctx = ADK.Context.for_child(cur_ctx, agent_spec)
        new_events = ADK.Agent.run(agent_spec, child_ctx)

        merged_ctx = merge_child_state(cur_ctx, child_ctx)

        halt? = Enum.any?(new_events, &escalated?/1)
        action = if halt?, do: :halt, else: :cont
        {action, {[new_events | evts], halt?, merged_ctx}}
      end)

    flat_events = events_acc |> Enum.reverse() |> List.flatten()
    new_acc = [flat_events | acc]

    cond do
      escalated? ->
        finalize_events(new_acc)

      is_function(exit_condition, 1) and exit_condition.(updated_ctx) ->
        finalize_events(new_acc)

      true ->
        do_loop(updated_ctx, agent, {iteration + 1, new_acc})
    end
  end

  defp merge_child_state(parent_ctx, child_ctx) do
    %{parent_ctx | temp_state: Map.merge(parent_ctx.temp_state, child_ctx.temp_state)}
  end

  defp finalize_events(acc) do
    acc |> Enum.reverse() |> List.flatten()
  end

  defp escalated?(%{actions: %{escalate: true}}), do: true

  defp escalated?(%{actions: actions}) when is_map(actions),
    do: Map.get(actions, :escalate, false)

  defp escalated?(_), do: false
end
