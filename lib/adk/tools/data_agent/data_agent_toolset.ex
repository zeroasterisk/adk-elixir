defmodule ADK.Tool.DataAgent.DataAgentToolset do
  @moduledoc """
  Data Agent Toolset contains tools for interacting with data agents.
  """

  alias ADK.Tool.DataAgent.DataAgentTool

  defstruct [
    :tool_filter,
    :credentials_config,
    :data_agent_tool_config
  ]

  @doc """
  Create a new DataAgentToolset.
  """
  def new(opts \\ []) do
    %__MODULE__{
      tool_filter: Keyword.get(opts, :tool_filter),
      credentials_config: Keyword.get(opts, :credentials_config),
      data_agent_tool_config: Keyword.get(opts, :data_agent_tool_config, %{})
    }
  end

  @doc """
  Returns a list of tools for the given toolset, filtered if tool_filter is present.
  """
  def get_tools(%__MODULE__{} = toolset) do
    all_tools = [
      %DataAgentTool{name: "list_accessible_data_agents"},
      %DataAgentTool{name: "get_data_agent_info"},
      %DataAgentTool{name: "ask_data_agent"}
    ]

    all_tools
    |> Enum.filter(&is_tool_selected?(&1, toolset.tool_filter))
  end

  defp is_tool_selected?(_tool, nil), do: true

  defp is_tool_selected?(tool, filter) when is_list(filter) do
    tool.name in filter
  end

  defp is_tool_selected?(tool, filter) when is_function(filter, 1) do
    filter.(tool)
  end

  defp is_tool_selected?(_tool, _), do: false
end
