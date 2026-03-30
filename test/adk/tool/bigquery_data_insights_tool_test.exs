defmodule ADK.Tool.BigQuery.DataInsightsToolTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.BigQuery.DataInsightsTool

  describe "ask_data_insights/6 pipeline from file" do
    test "ask_data_insights_pipeline_from_file (ask_data_insights_penguins_highest_mass.yaml)" do
      # 1. Construct the full, absolute path to the data file
      file_path =
        Path.join([__DIR__, "test_data", "ask_data_insights_penguins_highest_mass.yaml"])

      # 2. Load the test case data from the specified YAML file
      {:ok, case_data} = YamlElixir.read_from_file(file_path)

      # 3. Prepare the mock stream and expected output from the loaded data
      mock_stream_str = Map.get(case_data, "mock_api_stream")
      fake_stream_lines = String.split(mock_stream_str, "\n")
      expected_final_list = Map.get(case_data, "expected_output")

      # 4. Configure the mock stream fn
      stream_fn = fn -> fake_stream_lines end

      # 5. Call the function under test
      result =
        DataInsightsTool.ask_data_insights(
          "test-project",
          "test query",
          [],
          %{token: "fake-token"},
          %{max_query_result_rows: 50},
          stream_fn: stream_fn
        )

      # 6. Assert that the final list of dicts matches the expected output
      # We just test the response matches expected_final_list
      assert result["status"] == "SUCCESS"
      assert result["response"] == expected_final_list
    end
  end

  describe "ask_data_insights/6 success and exception handling" do
    test "ask_data_insights_success" do
      # 1. Configure the mocked behavior via get_stream_fn
      get_stream_fn = fn url, _ca_payload, headers, _max_rows, _opts ->
        # Verify headers inside the mock
        assert Enum.any?(headers, fn {k, v} -> k == "X-Goog-API-Client" and v == "GOOGLE_ADK" end)

        assert Enum.any?(headers, fn {k, v} ->
                 k == "Authorization" and v == "Bearer fake-token"
               end)

        assert String.contains?(url, "v1beta/projects/test-project/locations/global:chat")

        "Final formatted string from stream"
      end

      # 3. Call the function under test
      result =
        DataInsightsTool.ask_data_insights(
          "test-project",
          "test query",
          [],
          %{token: "fake-token"},
          %{max_query_result_rows: 100},
          get_stream_fn: get_stream_fn
        )

      # 4. Assert the results are as expected
      assert result["status"] == "SUCCESS"
      assert result["response"] == "Final formatted string from stream"
    end

    test "ask_data_insights_handles_exception" do
      # 1. Configure the mock to raise an error
      get_stream_fn = fn _url, _ca_payload, _headers, _max_rows, _opts ->
        raise "API call failed!"
      end

      # 3. Call the function
      result =
        DataInsightsTool.ask_data_insights(
          "test-project",
          "test query",
          [],
          %{token: "fake-token"},
          %{},
          get_stream_fn: get_stream_fn
        )

      # 4. Assert that the error was caught and formatted correctly
      assert result["status"] == "ERROR"
      assert String.contains?(result["error_details"], "API call failed!")
    end

    test "missing credentials" do
      result =
        DataInsightsTool.ask_data_insights(
          "test-project",
          "test query",
          [],
          nil,
          %{}
        )

      assert result["status"] == "ERROR"
      assert result["error_details"] == "ask_data_insights requires a valid access token."
    end
  end

  describe "append_message/2" do
    test "append_when_last_message_is_not_data" do
      initial = [%{"Thinking" => nil}, %{"Schema Resolved" => %{}}]
      new_msg = %{"SQL Generated" => "SELECT 1"}

      expected = [
        %{"Thinking" => nil},
        %{"Schema Resolved" => %{}},
        %{"SQL Generated" => "SELECT 1"}
      ]

      assert DataInsightsTool.append_message(initial, new_msg) == expected
    end

    test "replace_when_last_message_is_data" do
      initial = [%{"Thinking" => nil}, %{"Data Retrieved" => %{"rows" => [1]}}]
      new_msg = %{"Data Retrieved" => %{"rows" => [1, 2]}}
      expected = [%{"Thinking" => nil}, %{"Data Retrieved" => %{"rows" => [1, 2]}}]

      assert DataInsightsTool.append_message(initial, new_msg) == expected
    end

    test "append_to_an_empty_list" do
      initial = []
      new_msg = %{"Answer" => "First Message"}
      expected = [%{"Answer" => "First Message"}]

      assert DataInsightsTool.append_message(initial, new_msg) == expected
    end

    test "should_not_append_an_empty_new_message" do
      initial = [%{"Data Retrieved" => %{}}]
      new_msg = %{}
      expected = [%{"Data Retrieved" => %{}}]

      assert DataInsightsTool.append_message(initial, new_msg) == expected
    end
  end

  describe "handle_text_response/1" do
    test "multiple_parts" do
      response_dict = %{"parts" => ["The answer", " is 42."]}
      expected = %{"Answer" => "The answer is 42."}
      assert DataInsightsTool.handle_text_response(response_dict) == expected
    end

    test "single_part" do
      response_dict = %{"parts" => ["Hello"]}
      expected = %{"Answer" => "Hello"}
      assert DataInsightsTool.handle_text_response(response_dict) == expected
    end

    test "empty_response" do
      response_dict = %{}
      expected = %{"Answer" => ""}
      assert DataInsightsTool.handle_text_response(response_dict) == expected
    end
  end

  describe "handle_schema_response/1" do
    test "schema_query_path" do
      response_dict = %{"query" => %{"question" => "What is the schema?"}}
      expected = %{"Question" => "What is the schema?"}
      assert DataInsightsTool.handle_schema_response(response_dict) == expected
    end

    test "schema_result_path" do
      response_dict = %{
        "result" => %{
          "datasources" => [
            %{
              "bigqueryTableReference" => %{
                "projectId" => "p",
                "datasetId" => "d",
                "tableId" => "t"
              },
              "schema" => %{
                "fields" => [%{"name" => "col1", "type" => "STRING"}]
              }
            }
          ]
        }
      }

      expected = %{
        "Schema Resolved" => [
          %{
            "source_name" => "p.d.t",
            "schema" => %{
              "headers" => ["Column", "Type", "Description", "Mode"],
              "rows" => [["col1", "STRING", "", ""]]
            }
          }
        ]
      }

      assert DataInsightsTool.handle_schema_response(response_dict) == expected
    end
  end

  describe "handle_data_response/2" do
    test "format_generated_sql" do
      response_dict = %{"generatedSql" => "SELECT 1;"}
      expected = %{"SQL Generated" => "SELECT 1;"}
      assert DataInsightsTool.handle_data_response(response_dict, 100) == expected
    end

    test "format_data_result_table" do
      response_dict = %{
        "result" => %{
          "schema" => %{"fields" => [%{"name" => "id"}, %{"name" => "name"}]},
          "data" => [%{"id" => 1, "name" => "A"}, %{"id" => 2, "name" => "B"}]
        }
      }

      expected = %{
        "Data Retrieved" => %{
          "headers" => ["id", "name"],
          "rows" => [[1, "A"], [2, "B"]],
          "summary" => "Showing all 2 rows."
        }
      }

      assert DataInsightsTool.handle_data_response(response_dict, 100) == expected
    end

    test "format_data_result_table with truncation" do
      response_dict = %{
        "result" => %{
          "schema" => %{"fields" => [%{"name" => "id"}]},
          "data" => [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]
        }
      }

      expected = %{
        "Data Retrieved" => %{
          "headers" => ["id"],
          "rows" => [[1]],
          "summary" => "Showing the first 1 of 3 total rows."
        }
      }

      assert DataInsightsTool.handle_data_response(response_dict, 1) == expected
    end
  end

  describe "handle_error/1" do
    test "full_error_message" do
      response_dict = %{"code" => 404, "message" => "Not Found"}
      expected = %{"Error" => %{"Code" => 404, "Message" => "Not Found"}}
      assert DataInsightsTool.handle_error(response_dict) == expected
    end

    test "error_with_missing_message" do
      response_dict = %{"code" => 500}
      expected = %{"Error" => %{"Code" => 500, "Message" => "No message provided."}}
      assert DataInsightsTool.handle_error(response_dict) == expected
    end
  end
end
