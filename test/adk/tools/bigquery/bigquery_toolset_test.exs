defmodule ADK.Tool.BigQuery.BigQueryToolsetTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.BigQuery.BigQueryToolset
  alias ADK.Tool.BigQuery.CredentialsConfig
  alias ADK.Tool.BigQuery.Config

  setup do
    credentials_config = CredentialsConfig.new!(client_id: "abc", client_secret: "def")
    %{credentials_config: credentials_config}
  end

  test "test_bigquery_toolset_tools_default", %{credentials_config: credentials_config} do
    toolset =
      BigQueryToolset.new(
        credentials_config: credentials_config,
        bigquery_tool_config: nil
      )

    # Verify that the tool config is initialized to default values.
    assert %Config{} = toolset.bigquery_tool_config
    assert toolset.bigquery_tool_config == Config.new!()

    tools = BigQueryToolset.get_tools(toolset)
    assert length(tools) == 11

    expected_tool_names =
      MapSet.new([
        "list_dataset_ids",
        "get_dataset_info",
        "list_table_ids",
        "get_table_info",
        "get_job_info",
        "execute_sql",
        "ask_data_insights",
        "forecast",
        "analyze_contribution",
        "detect_anomalies",
        "search_catalog"
      ])

    actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))
    assert MapSet.equal?(actual_tool_names, expected_tool_names)
  end

  describe "test_bigquery_toolset_tools_selective" do
    test "None", %{credentials_config: credentials_config} do
      verify_selective_tools([], credentials_config)
    end

    test "dataset-metadata", %{credentials_config: credentials_config} do
      verify_selective_tools(["list_dataset_ids", "get_dataset_info"], credentials_config)
    end

    test "table-metadata", %{credentials_config: credentials_config} do
      verify_selective_tools(["list_table_ids", "get_table_info"], credentials_config)
    end

    test "query", %{credentials_config: credentials_config} do
      verify_selective_tools(["execute_sql"], credentials_config)
    end
  end

  defp verify_selective_tools(selected_tools, credentials_config) do
    toolset =
      BigQueryToolset.new(
        credentials_config: credentials_config,
        tool_filter: selected_tools
      )

    tools = BigQueryToolset.get_tools(toolset)
    assert length(tools) == length(selected_tools)

    expected_tool_names = MapSet.new(selected_tools)
    actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))
    assert MapSet.equal?(actual_tool_names, expected_tool_names)
  end

  describe "test_bigquery_toolset_unknown_tool" do
    test "all-unknown", %{credentials_config: credentials_config} do
      verify_unknown_tools(["unknown"], [], credentials_config)
    end

    test "mixed-known-unknown", %{credentials_config: credentials_config} do
      verify_unknown_tools(["unknown", "execute_sql"], ["execute_sql"], credentials_config)
    end
  end

  defp verify_unknown_tools(selected_tools, returned_tools, credentials_config) do
    toolset =
      BigQueryToolset.new(
        credentials_config: credentials_config,
        tool_filter: selected_tools
      )

    tools = BigQueryToolset.get_tools(toolset)
    assert length(tools) == length(returned_tools)

    expected_tool_names = MapSet.new(returned_tools)
    actual_tool_names = MapSet.new(Enum.map(tools, & &1.name))
    assert MapSet.equal?(actual_tool_names, expected_tool_names)
  end
end
