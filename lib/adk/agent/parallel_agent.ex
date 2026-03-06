defmodule ADK.Agent.ParallelAgent do
  @moduledoc """
  Runs sub-agents concurrently using `Task.async_stream`, collecting all events.

  This leverages OTP's lightweight process model — each sub-agent runs in its
  own task, and results are collected in order.

  ## Examples

      agent = ADK.Agent.ParallelAgent.new(
        name: "fan_out",
        sub_agents: [research_agent, analysis_agent, summary_agent]
      )
  """
  @behaviour ADK.Agent

  @default_timeout 30_000

  @doc """
  Create a parallel agent spec.

  ## Options

    * `:name` - agent name (default: `"parallel"`)
    * `:description` - agent description
    * `:sub_agents` - list of agent specs to run concurrently
    * `:timeout` - per-agent timeout in ms (default: #{@default_timeout})

  ## Examples

      iex> agent = ADK.Agent.ParallelAgent.new(name: "fan_out", sub_agents: [])
      iex> agent.name
      "fan_out"
  """
  @spec new(keyword()) :: ADK.Agent.t()
  def new(opts) do
    %{
      name: opts[:name] || "parallel",
      description: opts[:description] || "Runs agents in parallel",
      module: __MODULE__,
      config: %{
        sub_agents: opts[:sub_agents] || [],
        timeout: opts[:timeout] || @default_timeout
      },
      sub_agents: opts[:sub_agents] || []
    }
  end

  @impl true
  def run(ctx) do
    timeout = ctx.agent.config.timeout
    sub_agents = ctx.agent.config.sub_agents

    sub_agents
    |> Task.async_stream(
      fn agent_spec ->
        child_ctx = ADK.Context.for_child(ctx, agent_spec)
        agent_spec.module.run(child_ctx)
      end,
      timeout: timeout,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, events} -> events
      {:exit, reason} -> [ADK.Event.new(author: "parallel", content: "Agent failed: #{inspect(reason)}")]
    end)
  end
end
