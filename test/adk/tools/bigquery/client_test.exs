defmodule ADK.Tool.BigQuery.ClientTest do
  use ExUnit.Case, async: false
  alias ADK.Tool.BigQuery.Client

  @vsn (case :application.get_key(:adk, :vsn) do
          {:ok, vsn} -> to_string(vsn)
          _ -> "0.1.0"
        end)

  @expected_bq_agent "adk-bigquery-tool google-adk/#{@vsn}"
  @expected_dp_agent "adk-dataplex-tool google-adk/#{@vsn}"

  describe "get_bigquery_client/1" do
    test "test_bigquery_client_default" do
      client = Client.get_bigquery_client(project: "test-gcp-project", credentials: :mock_creds)
      assert client.project == "test-gcp-project"
      assert client.location == nil
    end

    test "test_bigquery_client_project_set_explicit" do
      System.delete_env("GOOGLE_CLOUD_PROJECT")
      client = Client.get_bigquery_client(project: "test-gcp-project", credentials: :mock_creds)
      assert client.project == "test-gcp-project"
    end

    test "test_bigquery_client_project_set_with_env" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "test-gcp-project")
      client = Client.get_bigquery_client(credentials: :mock_creds)
      assert client.project == "test-gcp-project"
      System.delete_env("GOOGLE_CLOUD_PROJECT")
    end

    test "test_bigquery_client_user_agent_default" do
      client = Client.get_bigquery_client(project: "test-gcp-project", credentials: :mock_creds)
      assert client.user_agent == @expected_bq_agent
    end

    test "test_bigquery_client_user_agent_custom" do
      client =
        Client.get_bigquery_client(
          project: "test-gcp-project",
          credentials: :mock_creds,
          user_agent: "custom_user_agent"
        )

      assert client.user_agent == "#{@expected_bq_agent} custom_user_agent"
    end

    test "test_bigquery_client_user_agent_custom_list" do
      client =
        Client.get_bigquery_client(
          project: "test-gcp-project",
          credentials: :mock_creds,
          user_agent: ["custom_user_agent1", "custom_user_agent2"]
        )

      assert client.user_agent == "#{@expected_bq_agent} custom_user_agent1 custom_user_agent2"
    end

    test "test_bigquery_client_location_custom" do
      client =
        Client.get_bigquery_client(
          project: "test-gcp-project",
          credentials: :mock_creds,
          location: "us-central1"
        )

      assert client.project == "test-gcp-project"
      assert client.location == "us-central1"
    end
  end

  describe "get_dataplex_catalog_client/1" do
    test "test_dataplex_client_default" do
      client = Client.get_dataplex_catalog_client(credentials: :mock_creds)
      assert client.user_agent == @expected_dp_agent
    end

    test "test_dataplex_client_custom_user_agent_str" do
      client =
        Client.get_dataplex_catalog_client(credentials: :mock_creds, user_agent: "catalog_ua/1.0")

      assert client.user_agent == "#{@expected_dp_agent} catalog_ua/1.0"
    end

    test "test_dataplex_client_custom_user_agent_list" do
      client =
        Client.get_dataplex_catalog_client(
          credentials: :mock_creds,
          user_agent: ["catalog_ua", "catalog_ua_2.0"]
        )

      assert client.user_agent == "#{@expected_dp_agent} catalog_ua catalog_ua_2.0"
    end

    test "test_dataplex_client_custom_user_agent_list_with_none" do
      client =
        Client.get_dataplex_catalog_client(
          credentials: :mock_creds,
          user_agent: ["catalog_ua", nil, "catalog_ua_2.0"]
        )

      assert client.user_agent == "#{@expected_dp_agent} catalog_ua catalog_ua_2.0"
    end
  end
end
