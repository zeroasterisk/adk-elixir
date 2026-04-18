defmodule ADK.Auth.Metadata do
  @moduledoc """
  Google Cloud Metadata Service client.
  """

  @metadata_url "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

  def get_token do
    resp =
      Req.get!(
        @metadata_url,
        headers: [{"metadata-flavor", "Google"}]
      )

    case resp.status do
      200 -> {:ok, resp.body["access_token"]}
      s -> {:error, {:metadata_token_error, s}}
    end
  rescue
    _ -> {:error, :no_credentials}
  end
end
