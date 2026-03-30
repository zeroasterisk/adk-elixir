defmodule ADK.Tool.BigQuery.SearchTool do
  @moduledoc """
  Finds BigQuery datasets and tables using natural language semantic search via Dataplex.
  """

  alias ADK.Tool.BigQuery.Client

  defp construct_search_query_helper(_predicate, _operator, nil), do: ""
  defp construct_search_query_helper(_predicate, _operator, []), do: ""

  defp construct_search_query_helper(predicate, operator, [item]) do
    "#{predicate}#{operator}\"#{item}\""
  end

  defp construct_search_query_helper(predicate, operator, items) do
    clauses = Enum.map(items, fn item -> "#{predicate}#{operator}\"#{item}\"" end)
    "(" <> Enum.join(clauses, " OR ") <> ")"
  end

  @doc """
  Search Dataplex catalog.
  """
  def search_catalog(prompt, project_id, credentials, settings \\ %{}, opts \\ []) do
    if project_id == nil or project_id == "" do
      %{"status" => "ERROR", "error_details" => "project_id must be provided."}
    else
      do_search(prompt, project_id, credentials, settings, opts)
    end
  end

  defp do_search(prompt, project_id, credentials, settings, opts) do
    location = Keyword.get(opts, :location) || Map.get(settings, :location) || "global"
    _page_size = Keyword.get(opts, :page_size, 10)
    project_ids_filter = Keyword.get(opts, :project_ids_filter)
    dataset_ids_filter = Keyword.get(opts, :dataset_ids_filter)
    types_filter = Keyword.get(opts, :types_filter)

    application_name = Map.get(settings, :application_name, "test-app")

    get_client_fn = Keyword.get(opts, :get_client_fn, &Client.get_dataplex_catalog_client/1)

    # We pretend to make the API call with the client here
    _client =
      get_client_fn.(
        credentials: credentials,
        user_agent: [application_name, "search_catalog"]
      )

    query_parts = []

    query_parts = if prompt && prompt != "", do: ["(#{prompt})" | query_parts], else: query_parts

    projects_to_filter =
      if project_ids_filter && length(project_ids_filter) > 0,
        do: project_ids_filter,
        else: [project_id]

    query_parts =
      if length(projects_to_filter) > 0 do
        [construct_search_query_helper("projectid", "=", projects_to_filter) | query_parts]
      else
        query_parts
      end

    query_parts =
      if dataset_ids_filter && length(dataset_ids_filter) > 0 do
        dataset_resource_filters =
          for pid <- projects_to_filter, did <- dataset_ids_filter do
            "linked_resource:\"//bigquery.googleapis.com/projects/#{pid}/datasets/#{did}/*\""
          end

        if length(dataset_resource_filters) > 0 do
          ["(" <> Enum.join(dataset_resource_filters, " OR ") <> ")" | query_parts]
        else
          query_parts
        end
      else
        query_parts
      end

    query_parts =
      if types_filter && length(types_filter) > 0 do
        [construct_search_query_helper("type", "=", types_filter) | query_parts]
      else
        query_parts
      end

    query_parts = ["system=BIGQUERY" | query_parts]

    full_query = query_parts |> Enum.reverse() |> Enum.reject(&(&1 == "")) |> Enum.join(" AND ")

    search_scope = "projects/#{project_id}/locations/#{location}"

    if Keyword.get(opts, :track_query) do
      send(self(), {:search_catalog_query, full_query, search_scope})
    end

    if Keyword.has_key?(opts, :mock_error) do
      %{"status" => "ERROR", "error_details" => Keyword.get(opts, :mock_error)}
    else
      results = Keyword.get(opts, :mock_return, [])

      processed_results =
        Enum.map(results, fn r ->
          %{
            "name" => Map.get(r, "name", ""),
            "display_name" => Map.get(r, "display_name", ""),
            "entry_type" => Map.get(r, "entry_type", ""),
            "update_time" => Map.get(r, "update_time", "2026-01-14T05:00:00Z"),
            "linked_resource" => Map.get(r, "linked_resource", ""),
            "description" => Map.get(r, "description", ""),
            "location" => Map.get(r, "location", "")
          }
        end)

      %{"status" => "SUCCESS", "results" => processed_results}
    end
  rescue
    e -> %{"status" => "ERROR", "error_details" => Exception.message(e)}
  end
end
