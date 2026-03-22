defmodule ADK.Tools.ApplicationIntegrationTool.Clients.ConnectionsClientTest do
  use ExUnit.Case, async: true
  alias ADK.Tool.ApplicationIntegrationTool.Clients.ConnectionsClient

  @project "test-project"
  @location "us-central1"
  @connection_name "test-connection"
  @credentials %{"email" => "test@example.com"} |> Jason.encode!()

  setup do
    client = ConnectionsClient.new(@project, @location, @connection_name, @credentials)
    %{client: client}
  end

  test "initialization", %{client: client} do
    assert client.project == @project
    assert client.location == @location
    assert client.connection == @connection_name
    assert client.connector_url == "https://connectors.googleapis.com"
    assert client.service_account_json == @credentials
    assert client.credential_cache == nil
  end

  test "execute_api_call success", %{client: client} do
    req_opts = [
      plug: fn conn ->
        assert conn.request_path == "/test"
        assert List.keymember?(conn.req_headers, "authorization", 0)
        Req.Test.json(conn, %{"data" => "test"})
      end
    ]

    client = %{client | req_opts: req_opts}
    response = invoke_private_execute_api_call(client, "https://test.url/test")
    assert response.body == %{"data" => "test"}
  end

  test "execute_api_call request_error_not_found_or_bad_request", %{client: client} do
    req_opts = [
      plug: fn conn ->
        conn |> Plug.Conn.send_resp(404, "Not Found")
      end
    ]

    client = %{client | req_opts: req_opts}

    assert_raise ArgumentError, ~r/Invalid request/, fn ->
      invoke_private_execute_api_call(client, "https://test.url")
    end
  end

  test "execute_api_call other request error", %{client: client} do
    req_opts = [
      plug: fn conn ->
        conn |> Plug.Conn.send_resp(500, "Internal Server Error")
      end
    ]

    client = %{client | req_opts: req_opts}

    assert_raise RuntimeError, ~r/Request error:/, fn ->
      invoke_private_execute_api_call(client, "https://test.url")
    end
  end

  test "get_connection_details success with host", %{client: client} do
    req_opts = [
      plug: fn conn ->
        Req.Test.json(conn, %{
          "name" => "test-connection",
          "serviceDirectory" => "test_service",
          "host" => "test.host",
          "tlsServiceDirectory" => "tls_test_service",
          "authOverrideEnabled" => true
        })
      end
    ]

    client = %{client | req_opts: req_opts}
    details = ConnectionsClient.get_connection_details(client)

    assert details == %{
             "name" => "test-connection",
             "serviceName" => "tls_test_service",
             "host" => "test.host",
             "authOverrideEnabled" => true
           }
  end

  test "get_connection_details success without host", %{client: client} do
    req_opts = [
      plug: fn conn ->
        Req.Test.json(conn, %{
          "name" => "test-connection",
          "serviceDirectory" => "test_service",
          "authOverrideEnabled" => false
        })
      end
    ]

    client = %{client | req_opts: req_opts}
    details = ConnectionsClient.get_connection_details(client)

    assert details == %{
             "name" => "test-connection",
             "serviceName" => "test_service",
             "host" => "",
             "authOverrideEnabled" => false
           }
  end

  test "get_entity_schema_and_operations success", %{client: client} do
    req_opts = [
      plug: fn conn ->
        if String.contains?(conn.request_path, "getEntityType") do
          Req.Test.json(conn, %{"name" => "operations/test_op"})
        else
          Req.Test.json(conn, %{
            "done" => true,
            "response" => %{
              "jsonSchema" => %{"type" => "object"},
              "operations" => ["LIST", "GET"]
            }
          })
        end
      end
    ]

    client = %{client | req_opts: req_opts}
    {schema, operations} = ConnectionsClient.get_entity_schema_and_operations(client, "entity1")
    assert schema == %{"type" => "object"}
    assert operations == ["LIST", "GET"]
  end

  test "get_action_schema success", %{client: client} do
    req_opts = [
      plug: fn conn ->
        if String.contains?(conn.request_path, "getAction") do
          Req.Test.json(conn, %{"name" => "operations/test_op"})
        else
          Req.Test.json(conn, %{
            "done" => true,
            "response" => %{
              "inputJsonSchema" => %{
                "type" => "object",
                "properties" => %{"input" => %{"type" => "string"}}
              },
              "outputJsonSchema" => %{
                "type" => "object",
                "properties" => %{"output" => %{"type" => "string"}}
              },
              "description" => "Test Action Description",
              "displayName" => "TestAction"
            }
          })
        end
      end
    ]

    client = %{client | req_opts: req_opts}
    schema = ConnectionsClient.get_action_schema(client, "action1")

    assert schema == %{
             "inputSchema" => %{
               "type" => "object",
               "properties" => %{"input" => %{"type" => "string"}}
             },
             "outputSchema" => %{
               "type" => "object",
               "properties" => %{"output" => %{"type" => "string"}}
             },
             "description" => "Test Action Description",
             "displayName" => "TestAction"
           }
  end

  test "static spec methods" do
    spec = ConnectionsClient.get_connector_base_spec()
    assert Map.has_key?(spec, "openapi")

    op =
      ConnectionsClient.get_action_operation(
        "TestAction",
        "EXECUTE_ACTION",
        "TestActionDisplayName",
        "test_tool"
      )

    assert get_in(op, ["post", "operationId"]) == "test_tool_TestActionDisplayName"

    list_op =
      ConnectionsClient.list_operation("Entity1", "{\\\"type\\\": \\\"object\\\"}", "test_tool")

    assert get_in(list_op, ["post", "summary"]) == "List Entity1"

    get_op =
      ConnectionsClient.get_operation("Entity1", "{\\\"type\\\": \\\"object\\\"}", "test_tool")

    assert get_in(get_op, ["post", "summary"]) == "Get Entity1"

    create_op = ConnectionsClient.create_operation("Entity1", "test_tool")
    assert get_in(create_op, ["post", "summary"]) == "Creates a new Entity1"

    req = ConnectionsClient.create_operation_request("Entity1")
    assert Map.get(req, "type") == "object"
  end

  test "connector_payload converts properly", %{client: client} do
    input_schema = %{
      "type" => "object",
      "properties" => %{
        "input" => %{
          "type" => ["null", "string"],
          "description" => "description"
        }
      }
    }

    output = ConnectionsClient.connector_payload(client, input_schema)

    assert output == %{
             "type" => "object",
             "properties" => %{
               "input" => %{
                 "type" => "string",
                 "nullable" => true,
                 "description" => "description"
               }
             }
           }
  end

  # Helper to invoke private methods if we need to
  # In Elixir, we can't easily invoke private functions from another module without a macro or changing to public.
  # Let's just make execute_api_call public for testing, or test through the public methods.
  # We test the public methods and they call execute_api_call, so we are good.
  # For the execute_api_call specific tests, we will just change the defp to @doc false def in the client,
  # or test it indirectly. Let's change defp to def in the Client for test parity.
  defp invoke_private_execute_api_call(client, url) do
    apply(ConnectionsClient, :execute_api_call, [client, url])
  end
end
