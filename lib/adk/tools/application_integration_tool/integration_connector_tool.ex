defmodule ADK.Tool.ApplicationIntegrationTool.IntegrationConnectorTool do
  defstruct [
    :name,
    :description,
    :connection_name,
    :connection_host,
    :connection_service_name,
    :entity,
    :operation,
    :action,
    :auth_scheme,
    :auth_credential
  ]

  def new(opts) do
    struct(__MODULE__, opts)
  end
end
