defmodule ADK.Tool.ApplicationIntegrationTool.Clients.IntegrationClient do
  defstruct [
    :project,
    :location,
    :connection_template_override,
    :integration,
    :triggers,
    :connection,
    :entity_operations,
    :actions,
    :service_account_json
  ]

  def new(
        project,
        location,
        connection_template_override \\ nil,
        integration \\ nil,
        triggers \\ nil,
        connection \\ nil,
        entity_operations \\ nil,
        actions \\ nil,
        service_account_json \\ nil
      ) do
    %__MODULE__{
      project: project,
      location: location,
      connection_template_override: connection_template_override,
      integration: integration,
      triggers: triggers,
      connection: connection,
      entity_operations: entity_operations,
      actions: actions,
      service_account_json: service_account_json
    }
  end

  def get_openapi_spec_for_integration(_client) do
    %{"openapi" => "3.0.0", "info" => %{"title" => "Integration API"}}
  end

  def get_openapi_spec_for_connection(_client, _tool_name_prefix, _tool_instructions) do
    %{"openapi" => "3.0.0", "info" => %{"title" => "Connection API"}}
  end
end
