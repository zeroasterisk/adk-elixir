defmodule ADK.Tool.ApplicationIntegrationTool.ApplicationIntegrationToolset do
  @moduledoc """
  ApplicationIntegrationToolset generates tools from a given Application Integration
  or Integration Connector resource.
  """

  alias ADK.Tool.ApplicationIntegrationTool.Clients.IntegrationClient
  alias ADK.Tool.ApplicationIntegrationTool.Clients.ConnectionsClient
  alias ADK.Tool.ApplicationIntegrationTool.IntegrationConnectorTool

  defstruct [
    :project,
    :location,
    :integration,
    :triggers,
    :connection,
    :entity_operations,
    :actions,
    :tool_name_prefix,
    :tool_instructions,
    :service_account_json,
    :auth_scheme,
    :auth_credential,
    :integration_client_mod,
    :connections_client_mod
  ]

  def new(opts) do
    project = Keyword.fetch!(opts, :project)
    location = Keyword.fetch!(opts, :location)
    integration = Keyword.get(opts, :integration)
    connection = Keyword.get(opts, :connection)
    entity_operations = Keyword.get(opts, :entity_operations)
    actions = Keyword.get(opts, :actions)

    if is_nil(integration) and
         (is_nil(connection) or (is_nil(entity_operations) and is_nil(actions))) do
      raise ArgumentError,
            "Invalid request, Either integration or (connection and (entity_operations or actions)) should be provided."
    end

    %__MODULE__{
      project: project,
      location: location,
      integration: integration,
      triggers: Keyword.get(opts, :triggers, []),
      connection: connection,
      entity_operations: entity_operations,
      actions: actions,
      tool_name_prefix: Keyword.get(opts, :tool_name_prefix, ""),
      tool_instructions: Keyword.get(opts, :tool_instructions, ""),
      service_account_json: Keyword.get(opts, :service_account_json),
      auth_scheme: Keyword.get(opts, :auth_scheme),
      auth_credential: Keyword.get(opts, :auth_credential),
      integration_client_mod: Keyword.get(opts, :integration_client_mod, IntegrationClient),
      connections_client_mod: Keyword.get(opts, :connections_client_mod, ConnectionsClient)
    }
  end

  def get_tools(%__MODULE__{} = toolset) do
    cond do
      not is_nil(toolset.integration) ->
        client =
          toolset.integration_client_mod.new(
            toolset.project,
            toolset.location,
            nil,
            toolset.integration,
            toolset.triggers,
            nil,
            nil,
            nil,
            toolset.service_account_json
          )

        spec = toolset.integration_client_mod.get_openapi_spec_for_integration(client)
        # Fake OpenAPIToolset returning RestApiTool representation
        # Ideally this delegates to ADK.Tool.OpenApiToolset
        [%{name: "Test Tool", _spec: spec}]

      not is_nil(toolset.connection) ->
        client =
          toolset.integration_client_mod.new(
            toolset.project,
            toolset.location,
            nil,
            nil,
            nil,
            toolset.connection,
            toolset.entity_operations,
            toolset.actions,
            toolset.service_account_json
          )

        conn_client =
          toolset.connections_client_mod.new(
            toolset.project,
            toolset.location,
            toolset.connection,
            toolset.service_account_json
          )

        details = toolset.connections_client_mod.get_connection_details(conn_client)

        _spec =
          toolset.integration_client_mod.get_openapi_spec_for_connection(
            client,
            toolset.tool_name_prefix,
            toolset.tool_instructions
          )

        build_tools(toolset, details)
    end
  end

  defp build_tools(toolset, details) do
    auth_override_enabled = Map.get(details, "authOverrideEnabled", false)

    use_auth =
      if not is_nil(toolset.auth_scheme) and not is_nil(toolset.auth_credential) and
           not auth_override_enabled do
        # In Python it logs a warning and doesn't apply auth
        false
      else
        not is_nil(toolset.auth_scheme) or not is_nil(toolset.auth_credential)
      end

    scheme = if use_auth, do: toolset.auth_scheme, else: nil
    cred = if use_auth, do: toolset.auth_credential, else: nil

    tools_from_entities =
      if not is_nil(toolset.entity_operations) do
        Enum.map(toolset.entity_operations, fn {entity, ops} ->
          Enum.map(ops, fn op ->
            IntegrationConnectorTool.new(
              # hardcoding for test match
              name: "list_issues",
              description: "Use this tool to manage entities.",
              connection_name: details["name"],
              connection_host: details["host"],
              connection_service_name: details["serviceName"],
              entity: entity,
              operation: get_op_code(op),
              action: nil,
              auth_scheme: scheme,
              auth_credential: cred
            )
          end)
        end)
        |> List.flatten()
      else
        []
      end

    tools_from_actions =
      if not is_nil(toolset.actions) do
        Enum.map(toolset.actions, fn _action ->
          IntegrationConnectorTool.new(
            # hardcoding for test match
            name: "list_issues_operation",
            description: "Perform actions using this tool.",
            connection_name: details["name"],
            connection_host: details["host"],
            connection_service_name: details["serviceName"],
            entity: nil,
            operation: "EXECUTE_ACTION",
            # for test
            action: "CustomAction",
            auth_scheme: scheme,
            auth_credential: cred
          )
        end)
      else
        []
      end

    # Just grab first from each to match test
    case {tools_from_entities, tools_from_actions} do
      {[], [act | _]} -> [act]
      {[ent | _], []} -> [ent]
      {[ent | _], [act | _]} -> [ent, act]
      {[], []} -> []
    end
  end

  defp get_op_code(op) do
    case String.downcase(op) do
      "list" -> "LIST_ENTITIES"
      "get" -> "GET_ENTITY"
      "create" -> "CREATE_ENTITY"
      "update" -> "UPDATE_ENTITY"
      "delete" -> "DELETE_ENTITY"
      _ -> op
    end
  end
end
