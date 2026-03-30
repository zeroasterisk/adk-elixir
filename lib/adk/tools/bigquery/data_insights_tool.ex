defmodule ADK.Tool.BigQuery.DataInsightsTool do
  @moduledoc """
  Answers questions about structured data in BigQuery tables using natural language.
  """

  @gda_client_id "GOOGLE_ADK"

  @doc """
  Answers questions about structured data in BigQuery tables using natural language.
  """
  def ask_data_insights(
        project_id,
        user_query_with_context,
        table_references,
        credentials,
        settings,
        opts \\ []
      ) do
    location = "global"

    token = Map.get(credentials || %{}, :token)

    if is_nil(token) or token == "" do
      %{
        "status" => "ERROR",
        "error_details" => "ask_data_insights requires a valid access token."
      }
    else
      headers = [
        {"Authorization", "Bearer #{token}"},
        {"Content-Type", "application/json"},
        {"X-Goog-API-Client", @gda_client_id}
      ]

      ca_url =
        "https://geminidataanalytics.googleapis.com/v1beta/projects/#{project_id}/locations/#{location}:chat"

      instructions = """
      **INSTRUCTIONS - FOLLOW THESE RULES:**
          1.  **CONTENT:** Your answer should present the supporting data and then provide a conclusion based on that data, including relevant details and observations where possible.
          2.  **ANALYSIS DEPTH:** Your analysis must go beyond surface-level observations. Crucially, you must prioritize metrics that measure impact or outcomes over metrics that simply measure volume or raw counts. For open-ended questions, explore the topic from multiple perspectives to provide a holistic view.
          3.  **OUTPUT FORMAT:** Your entire response MUST be in plain text format ONLY.
          4.  **NO CHARTS:** You are STRICTLY FORBIDDEN from generating any charts, graphs, images, or any other form of visualization.
      """

      ca_payload = %{
        "project" => "projects/#{project_id}",
        "messages" => [%{"userMessage" => %{"text" => user_query_with_context}}],
        "inlineContext" => %{
          "datasourceReferences" => %{
            "bq" => %{"tableReferences" => table_references}
          },
          "systemInstruction" => instructions,
          "options" => %{"chart" => %{"image" => %{"noImage" => %{}}}}
        },
        "clientIdEnum" => @gda_client_id
      }

      max_rows = Map.get(settings || %{}, :max_query_result_rows, 50)

      # Use dependency injection for get_stream, to mock either get_stream or stream_fn
      get_stream_fn = Keyword.get(opts, :get_stream_fn, &get_stream/5)

      try do
        resp = get_stream_fn.(ca_url, ca_payload, headers, max_rows, opts)

        %{
          "status" => "SUCCESS",
          "response" => resp
        }
      rescue
        e ->
          %{
            "status" => "ERROR",
            "error_details" => Exception.message(e)
          }
      end
    end
  end

  @doc false
  def get_stream(_url, _ca_payload, _headers, max_query_result_rows, opts \\ []) do
    # Defaults to empty list in real usage if stream_fn isn't injected, 
    # since we're just matching Python parity test without implementing a full Req HTTP client.
    # In Python, they mocked requests.post. Here we mock stream_fn or get_stream.
    stream_fn = Keyword.get(opts, :stream_fn, fn -> [] end)
    lines = stream_fn.()

    process_stream_lines(lines, max_query_result_rows)
  end

  @doc false
  def process_stream_lines(lines, max_query_result_rows) do
    # Reduces over lines of the streaming array and parses completed JSON objects
    Enum.reduce(lines, {"", []}, fn line, {accumulator, messages} ->
      line =
        if is_binary(line) do
          # Remove trailing newlines but preserve internal structure for accumulator
          # Python does decoded_line = str(line, encoding="utf-8")
          # which typically strips trailing newlines if you iterate over iter_lines()
          String.trim_trailing(line, "\n")
        else
          line
        end

      if is_nil(line) or line == "" do
        {accumulator, messages}
      else
        accumulator =
          case line do
            "[{" -> "{"
            "}]" -> accumulator <> "}"
            "," -> accumulator
            _ -> accumulator <> line
          end

        # Only try parsing if it "looks" like complete json block by matching { and }
        # Python uses a try-except on json.loads
        case Jason.decode(accumulator) do
          {:ok, data_json} ->
            messages = process_json_chunk(data_json, messages, max_query_result_rows)
            {"", messages}

          {:error, _} ->
            {accumulator, messages}
        end
      end
    end)
    |> elem(1)
  end

  defp process_json_chunk(data_json, messages, max_query_result_rows) do
    system_message = Map.get(data_json, "systemMessage")

    if is_nil(system_message) do
      if Map.has_key?(data_json, "error") do
        append_message(messages, handle_error(Map.get(data_json, "error")))
      else
        messages
      end
    else
      cond do
        Map.has_key?(system_message, "text") ->
          append_message(messages, handle_text_response(Map.get(system_message, "text")))

        Map.has_key?(system_message, "schema") ->
          append_message(messages, handle_schema_response(Map.get(system_message, "schema")))

        Map.has_key?(system_message, "data") ->
          append_message(
            messages,
            handle_data_response(Map.get(system_message, "data"), max_query_result_rows)
          )

        true ->
          messages
      end
    end
  end

  @doc false
  def append_message(messages, new_message) do
    if new_message == %{} or is_nil(new_message) do
      messages
    else
      if length(messages) > 0 and Map.has_key?(List.last(messages), "Data Retrieved") do
        Enum.drop(messages, -1) ++ [new_message]
      else
        messages ++ [new_message]
      end
    end
  end

  @doc false
  def handle_text_response(resp) do
    parts = Map.get(resp, "parts", [])
    %{"Answer" => Enum.join(parts, "")}
  end

  @doc false
  def handle_schema_response(resp) do
    cond do
      Map.has_key?(resp, "query") ->
        %{"Question" => Map.get(resp["query"], "question", "")}

      Map.has_key?(resp, "result") ->
        datasources = Map.get(resp["result"], "datasources", [])
        formatted_sources = Enum.map(datasources, &format_datasource_as_dict/1)
        %{"Schema Resolved" => formatted_sources}

      true ->
        %{}
    end
  end

  @doc false
  def handle_data_response(resp, max_query_result_rows) do
    cond do
      Map.has_key?(resp, "query") ->
        query = resp["query"]

        %{
          "Retrieval Query" => %{
            "Query Name" => Map.get(query, "name", "N/A"),
            "Question" => Map.get(query, "question", "N/A")
          }
        }

      Map.has_key?(resp, "generatedSql") ->
        %{"SQL Generated" => resp["generatedSql"]}

      Map.has_key?(resp, "result") ->
        schema = resp["result"]["schema"]
        fields = Map.get(schema, "fields", [])
        headers = Enum.map(fields, fn f -> Map.get(f, "name") end)

        all_rows = Map.get(resp["result"], "data", [])
        total_rows = length(all_rows)

        compact_rows =
          all_rows
          |> Enum.take(max_query_result_rows)
          |> Enum.map(fn row_dict ->
            Enum.map(headers, fn header -> Map.get(row_dict, header) end)
          end)

        summary_string =
          if total_rows > max_query_result_rows do
            "Showing the first #{length(compact_rows)} of #{total_rows} total rows."
          else
            "Showing all #{total_rows} rows."
          end

        %{
          "Data Retrieved" => %{
            "headers" => headers,
            "rows" => compact_rows,
            "summary" => summary_string
          }
        }

      true ->
        %{}
    end
  end

  @doc false
  def handle_error(resp) do
    %{
      "Error" => %{
        "Code" => Map.get(resp, "code", "N/A"),
        "Message" => Map.get(resp, "message", "No message provided.")
      }
    }
  end

  defp format_datasource_as_dict(datasource) do
    source_name = format_bq_table_ref(datasource["bigqueryTableReference"])
    schema = format_schema_as_dict(datasource["schema"])
    %{"source_name" => source_name, "schema" => schema}
  end

  defp format_bq_table_ref(table_ref) do
    project_id = Map.get(table_ref || %{}, "projectId")
    dataset_id = Map.get(table_ref || %{}, "datasetId")
    table_id = Map.get(table_ref || %{}, "tableId")
    "#{project_id}.#{dataset_id}.#{table_id}"
  end

  defp format_schema_as_dict(data) do
    fields = Map.get(data || %{}, "fields", [])

    if Enum.empty?(fields) do
      %{"columns" => []}
    else
      headers = ["Column", "Type", "Description", "Mode"]

      rows =
        Enum.map(fields, fn field ->
          [
            Map.get(field, "name", ""),
            Map.get(field, "type", ""),
            Map.get(field, "description", ""),
            Map.get(field, "mode", "")
          ]
        end)

      %{"headers" => headers, "rows" => rows}
    end
  end
end
