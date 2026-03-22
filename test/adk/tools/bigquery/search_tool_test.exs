defmodule ADK.Tool.BigQuery.SearchToolTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.BigQuery.SearchTool

  @mock_credentials %{token: "test_token"}
  @mock_settings %{application_name: "test-app"}

  describe "search_catalog" do
    test "search_catalog_success" do
      prompt = "customer data"
      project_id = "test-project"
      location = "us"

      mock_results = [
        %{
          "name" => "entry1",
          "entry_type" => "TABLE",
          "display_name" => "Cust Table",
          "linked_resource" => "//bigquery.googleapis.com/projects/p/datasets/d/tables/t1",
          "description" => "Table 1",
          "location" => "us"
        }
      ]

      result = SearchTool.search_catalog(prompt, project_id, @mock_credentials, @mock_settings, 
        location: location, 
        mock_return: mock_results, 
        track_query: true
      )

      assert result["status"] == "SUCCESS"
      assert length(result["results"]) == 1
      assert Enum.at(result["results"], 0)["name"] == "entry1"
      assert Enum.at(result["results"], 0)["display_name"] == "Cust Table"

      assert_received {:search_catalog_query, query, search_scope}
      assert query == "(customer data) AND projectid=\"test-project\" AND system=BIGQUERY"
      assert search_scope == "projects/test-project/locations/us"
    end

    test "search_catalog_no_project_id" do
      result = SearchTool.search_catalog("test", "", @mock_credentials, @mock_settings, location: "us")
      assert result["status"] == "ERROR"
      assert result["error_details"] =~ "project_id must be provided"
    end

    test "search_catalog_api_error" do
      result = SearchTool.search_catalog("test", "test-project", @mock_credentials, @mock_settings, 
        location: "us", 
        mock_error: "Dataplex API Error: 400 Invalid query"
      )
      assert result["status"] == "ERROR"
      assert result["error_details"] =~ "Dataplex API Error: 400 Invalid query"
    end

    test "search_catalog_other_exception" do
      result = SearchTool.search_catalog("test", "test-project", @mock_credentials, @mock_settings, 
        location: "us", 
        mock_error: "Something went wrong"
      )
      assert result["status"] == "ERROR"
      assert result["error_details"] =~ "Something went wrong"
    end

    test "search_catalog_query_construction project_filter" do
      SearchTool.search_catalog("p", "test-project", @mock_credentials, @mock_settings, 
        project_ids_filter: ["proj1"], 
        mock_return: [], 
        track_query: true
      )
      assert_received {:search_catalog_query, query, _scope}
      assert query =~ "(p) AND projectid=\"proj1\" AND system=BIGQUERY"
    end

    test "search_catalog_query_construction multi_project_filter" do
      SearchTool.search_catalog("p", "test-project", @mock_credentials, @mock_settings, 
        project_ids_filter: ["p1", "p2"], 
        mock_return: [], 
        track_query: true
      )
      assert_received {:search_catalog_query, query, _scope}
      assert query =~ "(p) AND (projectid=\"p1\" OR projectid=\"p2\") AND system=BIGQUERY"
    end

    test "search_catalog_query_construction type_filter" do
      SearchTool.search_catalog("p", "test-project", @mock_credentials, @mock_settings, 
        types_filter: ["TABLE"], 
        mock_return: [], 
        track_query: true
      )
      assert_received {:search_catalog_query, query, _scope}
      assert query =~ "(p) AND projectid=\"test-project\" AND type=\"TABLE\" AND system=BIGQUERY"
    end

    test "search_catalog_query_construction multi_type_filter" do
      SearchTool.search_catalog("p", "test-project", @mock_credentials, @mock_settings, 
        types_filter: ["TABLE", "DATASET"], 
        mock_return: [], 
        track_query: true
      )
      assert_received {:search_catalog_query, query, _scope}
      assert query =~ "(p) AND projectid=\"test-project\" AND (type=\"TABLE\" OR type=\"DATASET\") AND system=BIGQUERY"
    end

    test "search_catalog_query_construction project_and_dataset_filters" do
      SearchTool.search_catalog("inventory", "test-project", @mock_credentials, @mock_settings, 
        project_ids_filter: ["proj1", "proj2"], 
        dataset_ids_filter: ["dsetA"], 
        mock_return: [], 
        track_query: true
      )
      assert_received {:search_catalog_query, query, _scope}
      assert query =~ "(inventory)"
      assert query =~ "(projectid=\"proj1\" OR projectid=\"proj2\")"
      assert query =~ "(linked_resource:\"//bigquery.googleapis.com/projects/proj1/datasets/dsetA/*\" OR linked_resource:\"//bigquery.googleapis.com/projects/proj2/datasets/dsetA/*\")"
      assert query =~ "system=BIGQUERY"
    end

    test "search_catalog_no_app_name" do
      # Just verify it doesn't crash when application_name is missing
      result = SearchTool.search_catalog("test", "test-project", @mock_credentials, %{}, mock_return: [])
      assert result["status"] == "SUCCESS"
    end

    test "search_catalog_multi_project_filter_semantic" do
      prompt = "What datasets store user profiles?"
      project_id = "main-project"
      project_filters = ["user-data-proj", "shared-infra-proj"]
      location = "global"

      SearchTool.search_catalog(prompt, project_id, @mock_credentials, @mock_settings, 
        location: location, 
        project_ids_filter: project_filters, 
        types_filter: ["DATASET"], 
        mock_return: [], 
        track_query: true
      )

      assert_received {:search_catalog_query, query, search_scope}
      assert query =~ "(What datasets store user profiles?) AND (projectid=\"user-data-proj\" OR projectid=\"shared-infra-proj\") AND type=\"DATASET\" AND system=BIGQUERY"
      assert search_scope == "projects/main-project/locations/global"
    end

    test "search_catalog_natural_language_semantic" do
      prompt = "Find tables about football matches"
      project_id = "sports-analytics"
      location = "europe-west1"

      mock_api_results = [
        %{
          "name" => "projects/sports-analytics/locations/europe-west1/entryGroups/@bigquery/entries/fb1",
          "display_name" => "uk_football_premiership",
          "entry_type" => "projects/655216118709/locations/global/entryTypes/bigquery-table",
          "linked_resource" => "//bigquery.googleapis.com/projects/sports-analytics/datasets/uk/tables/premiership",
          "description" => "Stats for UK Premier League matches.",
          "location" => "europe-west1"
        },
        %{
          "name" => "projects/sports-analytics/locations/europe-west1/entryGroups/@bigquery/entries/fb2",
          "display_name" => "serie_a_matches",
          "entry_type" => "projects/655216118709/locations/global/entryTypes/bigquery-table",
          "linked_resource" => "//bigquery.googleapis.com/projects/sports-analytics/datasets/italy/tables/serie_a",
          "description" => "Italian Serie A football results.",
          "location" => "europe-west1"
        }
      ]

      result = SearchTool.search_catalog(prompt, project_id, @mock_credentials, @mock_settings, 
        location: location, 
        mock_return: mock_api_results, 
        track_query: true
      )

      assert result["status"] == "SUCCESS"
      assert length(result["results"]) == 2
      assert Enum.at(result["results"], 0)["display_name"] == "uk_football_premiership"
      assert Enum.at(result["results"], 1)["display_name"] == "serie_a_matches"
      assert Enum.at(result["results"], 0)["description"] =~ "UK Premier League"

      assert_received {:search_catalog_query, query, search_scope}
      assert query == "(Find tables about football matches) AND projectid=\"sports-analytics\" AND system=BIGQUERY"
      assert search_scope == "projects/sports-analytics/locations/europe-west1"
    end

    test "search_catalog_default_location" do
      SearchTool.search_catalog("test", "test-project", @mock_credentials, @mock_settings, 
        mock_return: [], 
        track_query: true
      )
      
      assert_received {:search_catalog_query, _query, search_scope}
      assert search_scope == "projects/test-project/locations/global"
    end

    test "search_catalog_settings_location" do
      SearchTool.search_catalog("test", "test-project", @mock_credentials, %{application_name: "test-app", location: "eu"}, 
        mock_return: [], 
        track_query: true
      )
      
      assert_received {:search_catalog_query, _query, search_scope}
      assert search_scope == "projects/test-project/locations/eu"
    end
  end
end
