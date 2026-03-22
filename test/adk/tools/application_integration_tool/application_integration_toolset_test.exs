defmodule ADK.Tool.ApplicationIntegrationTool.ApplicationIntegrationToolsetTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.ApplicationIntegrationTool.ApplicationIntegrationToolset
  alias ADK.Tool.ApplicationIntegrationTool.IntegrationConnectorTool

  defmodule MockIntegrationClient do
    def new(
          _project,
          _location,
          _conn_override,
          _integration,
          _triggers,
          _conn,
          _entity_ops,
          _actions,
          sa_json
        ) do
      %{service_account_json: sa_json}
    end

    def get_openapi_spec_for_integration(_client) do
      %{"openapi" => "3.0.0", "info" => %{"title" => "Integration API"}}
    end

    def get_openapi_spec_for_connection(_client, _prefix, _instructions) do
      %{"openapi" => "3.0.0", "info" => %{"title" => "Connection API"}}
    end
  end

  defmodule MockConnectionsClient do
    def new(_project, _location, _connection, _sa_json) do
      %{}
    end

    def get_connection_details(_client) do
      Process.get(:mock_conn_details, %{
        "serviceName" => "test-service",
        "host" => "test.host",
        "name" => "test-connection",
        "authOverrideEnabled" => false
      })
    end
  end

  setup do
    %{
      project: "test-project",
      location: "us-central1"
    }
  end

  test "initialization with integration and trigger", %{project: project, location: location} do
    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        integration: "test-integration",
        triggers: ["test-trigger"],
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert length(tools) == 1
    assert hd(tools).name == "Test Tool"
  end

  test "initialization with integration and list of triggers", %{
    project: project,
    location: location
  } do
    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        integration: "test-integration",
        triggers: ["test-trigger1", "test-trigger2"],
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert length(tools) == 1
    assert hd(tools).name == "Test Tool"
  end

  test "initialization with integration and empty trigger list", %{
    project: project,
    location: location
  } do
    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        integration: "test-integration",
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert length(tools) == 1
    assert hd(tools).name == "Test Tool"
  end

  test "initialization with connection and entity operations", %{
    project: project,
    location: location
  } do
    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        connection: "test-connection",
        entity_operations: %{"Issues" => ["list", "get"]},
        tool_name_prefix: "My Connection Tool",
        tool_instructions: "Use this tool to manage entities.",
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert length(tools) == 1

    tool = hd(tools)
    assert tool.name == "list_issues"
    assert tool.entity == "Issues"
    assert tool.operation == "LIST_ENTITIES"
    assert %IntegrationConnectorTool{} = tool
  end

  test "initialization with connection and actions", %{project: project, location: location} do
    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        connection: "test-connection",
        actions: ["create", "delete"],
        tool_name_prefix: "My Actions Tool",
        tool_instructions: "Perform actions using this tool.",
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert length(tools) == 1

    tool = hd(tools)
    assert tool.name == "list_issues_operation"
    assert tool.action == "CustomAction"
    assert tool.operation == "EXECUTE_ACTION"
    assert %IntegrationConnectorTool{} = tool
  end

  test "initialization without required params", %{project: project, location: location} do
    assert_raise ArgumentError, ~r/Invalid request, Either integration or/, fn ->
      ApplicationIntegrationToolset.new(project: project, location: location)
    end

    assert_raise ArgumentError, ~r/Invalid request, Either integration or/, fn ->
      ApplicationIntegrationToolset.new(project: project, location: location, triggers: ["test"])
    end

    assert_raise ArgumentError, ~r/Invalid request, Either integration or/, fn ->
      ApplicationIntegrationToolset.new(project: project, location: location, connection: "test")
    end
  end

  test "initialization with service account credentials", %{project: project, location: location} do
    sa_json = "{\"type\": \"service_account\"}"

    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        integration: "test-integration",
        triggers: ["test-trigger"],
        service_account_json: sa_json,
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    assert toolset.service_account_json == sa_json
  end

  test "initialization without explicit service account credentials", %{
    project: project,
    location: location
  } do
    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        integration: "test-integration",
        triggers: ["test-trigger"],
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    assert is_nil(toolset.service_account_json)
  end

  test "get tools", %{project: project, location: location} do
    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        integration: "test-integration",
        triggers: ["test-trigger"],
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert length(tools) == 1
    assert hd(tools).name == "Test Tool"
  end

  test "initialization with connection details", %{project: project, location: location} do
    Process.put(:mock_conn_details, %{
      "serviceName" => "custom-service",
      "host" => "custom.host",
      "name" => "test-connection",
      "authOverrideEnabled" => false
    })

    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        connection: "test-connection",
        entity_operations: %{"Issues" => ["list"]},
        tool_name_prefix: "My Connection Tool",
        tool_instructions: "Use this tool.",
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert hd(tools).connection_host == "custom.host"
    assert hd(tools).connection_service_name == "custom-service"
  end

  test "initialization with connection and custom auth", %{project: project, location: location} do
    Process.put(:mock_conn_details, %{
      "serviceName" => "test-service",
      "host" => "test.host",
      "name" => "test-connection",
      "authOverrideEnabled" => true
    })

    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        connection: "test-connection",
        actions: ["create", "delete"],
        tool_name_prefix: "My Actions Tool",
        tool_instructions: "Perform actions using this tool.",
        auth_scheme: %{type: "oauth2"},
        auth_credential: %{token: "test"},
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert length(tools) == 1
    tool = hd(tools)

    assert tool.auth_scheme == %{type: "oauth2"}
    assert tool.auth_credential == %{token: "test"}
  end

  test "initialization with connection with auth override disabled and custom auth", %{
    project: project,
    location: location
  } do
    Process.put(:mock_conn_details, %{
      "serviceName" => "test-service",
      "host" => "test.host",
      "name" => "test-connection",
      "authOverrideEnabled" => false
    })

    toolset =
      ApplicationIntegrationToolset.new(
        project: project,
        location: location,
        connection: "test-connection",
        actions: ["create", "delete"],
        tool_name_prefix: "My Actions Tool",
        tool_instructions: "Perform actions using this tool.",
        auth_scheme: %{type: "oauth2"},
        auth_credential: %{token: "test"},
        integration_client_mod: MockIntegrationClient,
        connections_client_mod: MockConnectionsClient
      )

    tools = ApplicationIntegrationToolset.get_tools(toolset)
    assert length(tools) == 1
    tool = hd(tools)

    assert is_nil(tool.auth_scheme)
    assert is_nil(tool.auth_credential)
  end
end
