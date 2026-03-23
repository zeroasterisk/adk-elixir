defmodule ADK.Tool.DataAgent.DataAgentToolsetTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.DataAgent.DataAgentToolset
  alias ADK.Tool.DataAgent.DataAgentTool
  alias ADK.Tool.DataAgent.CredentialsConfig
  alias ADK.Tool.DataAgent.ToolConfig

  describe "DataAgentToolset" do
    test "tools_default - returns all default tools" do
      credentials_config = CredentialsConfig.new(client_id: "abc", client_secret: "def")

      # tool_filter is nil by default
      toolset =
        DataAgentToolset.new(
          credentials_config: credentials_config,
          data_agent_tool_config: ToolConfig.new()
        )

      # Verify that the tool config is initialized to default values.
      assert %ToolConfig{max_query_result_rows: 50} = toolset.data_agent_tool_config

      tools = DataAgentToolset.get_tools(toolset)

      assert tools != nil
      assert length(tools) == 3
      assert Enum.all?(tools, fn tool -> match?(%DataAgentTool{}, tool) end)

      expected_tool_names =
        MapSet.new([
          "list_accessible_data_agents",
          "get_data_agent_info",
          "ask_data_agent"
        ])

      actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))

      assert actual_tool_names == expected_tool_names
    end

    test "tools_selective - list_and_get" do
      credentials_config = CredentialsConfig.new(client_id: "abc", client_secret: "def")
      selected_tools = ["list_accessible_data_agents", "get_data_agent_info"]

      toolset =
        DataAgentToolset.new(
          credentials_config: credentials_config,
          tool_filter: selected_tools
        )

      tools = DataAgentToolset.get_tools(toolset)

      assert length(tools) == length(selected_tools)
      assert Enum.all?(tools, fn tool -> match?(%DataAgentTool{}, tool) end)

      expected_tool_names = MapSet.new(selected_tools)
      actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))

      assert actual_tool_names == expected_tool_names
    end

    test "tools_selective - ask" do
      credentials_config = CredentialsConfig.new(client_id: "abc", client_secret: "def")
      selected_tools = ["ask_data_agent"]

      toolset =
        DataAgentToolset.new(
          credentials_config: credentials_config,
          tool_filter: selected_tools
        )

      tools = DataAgentToolset.get_tools(toolset)

      assert length(tools) == length(selected_tools)
      assert Enum.all?(tools, fn tool -> match?(%DataAgentTool{}, tool) end)

      expected_tool_names = MapSet.new(selected_tools)
      actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))

      assert actual_tool_names == expected_tool_names
    end

    test "tools_selective - empty" do
      credentials_config = CredentialsConfig.new(client_id: "abc", client_secret: "def")
      selected_tools = []

      toolset =
        DataAgentToolset.new(
          credentials_config: credentials_config,
          tool_filter: selected_tools
        )

      tools = DataAgentToolset.get_tools(toolset)

      assert length(tools) == length(selected_tools)
      assert Enum.all?(tools, fn tool -> match?(%DataAgentTool{}, tool) end)

      expected_tool_names = MapSet.new(selected_tools)
      actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))

      assert actual_tool_names == expected_tool_names
    end

    test "unknown_tool - all unknown" do
      credentials_config = CredentialsConfig.new(client_id: "abc", client_secret: "def")
      selected_tools = ["unknown"]

      toolset =
        DataAgentToolset.new(
          credentials_config: credentials_config,
          tool_filter: selected_tools
        )

      tools = DataAgentToolset.get_tools(toolset)

      assert length(tools) == 0
      assert Enum.all?(tools, fn tool -> match?(%DataAgentTool{}, tool) end)

      expected_tool_names = MapSet.new([])
      actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))

      assert actual_tool_names == expected_tool_names
    end

    test "unknown_tool - mixed known and unknown" do
      credentials_config = CredentialsConfig.new(client_id: "abc", client_secret: "def")
      selected_tools = ["unknown", "ask_data_agent"]
      returned_tools = ["ask_data_agent"]

      toolset =
        DataAgentToolset.new(
          credentials_config: credentials_config,
          tool_filter: selected_tools
        )

      tools = DataAgentToolset.get_tools(toolset)

      assert length(tools) == length(returned_tools)
      assert Enum.all?(tools, fn tool -> match?(%DataAgentTool{}, tool) end)

      expected_tool_names = MapSet.new(returned_tools)
      actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))

      assert actual_tool_names == expected_tool_names
    end
  end
end
