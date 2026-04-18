defmodule ADK.Auth.Metadata do
  @moduledoc """
  Google Cloud Metadata Service client.
  """

  @metadata_url "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

  def get_token do
    case Req.get(@metadata_url, headers: [{"metadata-flavor", "Google"}]) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body["access_token"]}

      {:ok, %{status: s}} ->
        {:error, {:metadata_token_error, s}}

      {:error, _} ->
        {:error, :no_credentials}
    end
  end
end
