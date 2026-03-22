defmodule ADK.Tool.BigQuery.BigQueryToolset do
  @moduledoc """
  BigQuery Toolset contains tools for interacting with BigQuery data and metadata.
  """

  alias ADK.Tool.BigQuery.Config
  alias ADK.Tool.BigQuery.CredentialsConfig
  alias ADK.Tool.BigQuery.MetadataTool
  alias ADK.Tool.BigQuery.QueryTool
  alias ADK.Tool.BigQuery.DataInsightsTool
  alias ADK.Tool.BigQuery.SearchTool

  defstruct [
    :tool_filter,
    :credentials_config,
    :bigquery_tool_config
  ]

  @type t :: %__MODULE__{
          tool_filter: [String.t()] | (map() -> boolean()) | nil,
          credentials_config: CredentialsConfig.t() | nil,
          bigquery_tool_config: Config.t()
        }

  @doc "Creates a new BigQuery Toolset."
  def new(opts \\ []) do
    config = Keyword.get(opts, :bigquery_tool_config)
    config = if is_nil(config), do: Config.new!(), else: config

    %__MODULE__{
      tool_filter: Keyword.get(opts, :tool_filter),
      credentials_config: Keyword.get(opts, :credentials_config),
      bigquery_tool_config: config
    }
  end

  def get_auth_config(_toolset \\ nil), do: nil

  def get_tools(%__MODULE__{} = toolset, context \\ nil) do
    all_tools = build_all_tools(toolset)
    apply_filter(all_tools, toolset.tool_filter, context)
  end

  def close(_toolset \\ nil), do: :ok

  defp build_all_tools(toolset) do
    creds = toolset.credentials_config
    settings = toolset.bigquery_tool_config

    [
      ADK.Tool.FunctionTool.new("list_dataset_ids",
        description: "List dataset IDs.",
        func: fn _ctx, %{"project" => p} ->
          MetadataTool.list_dataset_ids(p, creds, settings)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("get_dataset_info",
        description: "Get information about a dataset.",
        func: fn _ctx, %{"project" => p, "dataset" => d} ->
          MetadataTool.get_dataset_info(p, d, creds, settings)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("list_table_ids",
        description: "List table IDs.",
        func: fn _ctx, %{"project" => p, "dataset" => d} ->
          MetadataTool.list_table_ids(p, d, creds, settings)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("get_table_info",
        description: "Get information about a table.",
        func: fn _ctx, %{"project" => p, "dataset" => d, "table_id" => t} ->
          MetadataTool.get_table_info(p, d, t, creds, settings)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("get_job_info",
        description: "Get job info.",
        func: fn _ctx, %{"project" => p, "job_id" => j} ->
          MetadataTool.get_job_info(p, j, creds, settings)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("execute_sql",
        description: "Execute SQL.",
        func: fn ctx, %{"project_id" => p, "query" => q} ->
          QueryTool.execute_sql(p, q, creds, settings, ctx)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("ask_data_insights",
        description: "Ask data insights.",
        func: fn _ctx,
                 %{"project_id" => p, "user_query_with_context" => u, "table_references" => tr} ->
          DataInsightsTool.ask_data_insights(p, u, tr, creds, settings)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("forecast",
        description: "Forecast.",
        func: fn ctx,
                 %{"project_id" => p, "history_data" => h, "timestamp_col" => t, "data_col" => d} ->
          QueryTool.forecast(p, h, t, d, creds, settings, ctx)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("analyze_contribution",
        description: "Analyze contribution.",
        func: fn ctx,
                 %{
                   "project_id" => p,
                   "input_data" => i,
                   "dimension_id_cols" => dc,
                   "contribution_metric" => cm,
                   "is_test_col" => itc
                 } ->
          QueryTool.analyze_contribution(p, i, dc, cm, itc, creds, settings, ctx)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("detect_anomalies",
        description: "Detect anomalies.",
        func: fn ctx,
                 %{
                   "project_id" => p,
                   "history_data" => h,
                   "times_series_timestamp_col" => ts,
                   "times_series_data_col" => td
                 } ->
          QueryTool.detect_anomalies(p, h, ts, td, creds, settings, ctx)
        end,
        parameters: %{}
      ),
      ADK.Tool.FunctionTool.new("search_catalog",
        description: "Search Dataplex catalog.",
        func: fn _ctx, %{"prompt" => pr, "project_id" => pid} ->
          SearchTool.search_catalog(pr, pid, creds, settings)
        end,
        parameters: %{}
      )
    ]
  end

  defp apply_filter(tools, nil, _context), do: tools

  defp apply_filter(tools, names, _context) when is_list(names) do
    name_set = MapSet.new(names)
    Enum.filter(tools, fn %{name: tool_name} -> MapSet.member?(name_set, tool_name) end)
  end

  defp apply_filter(tools, pred, context) when is_function(pred, 2) do
    Enum.filter(tools, fn tool -> pred.(tool, context) end)
  end

  defp apply_filter(tools, pred, _context) when is_function(pred, 1) do
    Enum.filter(tools, fn tool -> pred.(tool) end)
  end
end
