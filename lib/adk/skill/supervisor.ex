defmodule ADK.Skill.Supervisor do
  @moduledoc """
  DynamicSupervisor that manages MCP server processes for a skill.

  Started when a skill with `mcp.json` is loaded. Children are
  `ADK.MCP.Toolset` processes with `:one_for_one` strategy.
  """

  use DynamicSupervisor

  @doc "Start the skill supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name_opts, _rest} = Keyword.split(opts, [:name])
    DynamicSupervisor.start_link(__MODULE__, [], name_opts)
  end

  @doc "Start an MCP Toolset as a child of this supervisor."
  @spec start_mcp_toolset(pid(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_mcp_toolset(supervisor, toolset_opts) do
    spec = %{
      id: make_ref(),
      start: {ADK.MCP.Toolset, :start_link, [toolset_opts]},
      restart: :transient,
      shutdown: 5_000
    }

    DynamicSupervisor.start_child(supervisor, spec)
  end

  @doc "Stop the supervisor and all its children."
  @spec stop(pid()) :: :ok
  def stop(supervisor) do
    if Process.alive?(supervisor) do
      DynamicSupervisor.stop(supervisor, :normal, 5_000)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
