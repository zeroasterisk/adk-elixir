defmodule ADK.Artifact.GCS do
  @moduledoc """
  Google Cloud Storage artifact backend.

  Stores artifacts as objects in a GCS bucket using the JSON API via `Req`.
  Authentication uses Application Default Credentials (ADC) — either a service
  account JSON file pointed to by `GOOGLE_APPLICATION_CREDENTIALS` or
  Compute Engine metadata.

  ## Path layout

      gs://bucket/app_name/user_id/session_id/filename/v0
      gs://bucket/app_name/user_id/session_id/filename/v1

  ## Configuration

      artifact_service: {ADK.Artifact.GCS, bucket: "my-bucket"}

  ## Options

    * `:bucket` — GCS bucket name (required)
    * `:credentials_file` — path to service account JSON (defaults to `GOOGLE_APPLICATION_CREDENTIALS`)
  """

  @behaviour ADK.Artifact.Store

  @gcs_upload_url "https://storage.googleapis.com/upload/storage/v1"
  @gcs_api_url "https://storage.googleapis.com/storage/v1"
  @scopes ["https://www.googleapis.com/auth/devstorage.read_write"]

  @impl true
  def save(app_name, user_id, session_id, filename, artifact, opts \\ []) do
    bucket = Keyword.fetch!(opts, :bucket)

    with {:ok, token} <- get_access_token(opts),
         {:ok, version} <- next_version(bucket, token, app_name, user_id, session_id, filename) do
      object_name = object_path(app_name, user_id, session_id, filename, version)
      content_type = artifact[:content_type] || "application/octet-stream"
      metadata = artifact[:metadata] || %{}

      body = artifact[:data] || ""

      resp =
        Req.post!(
          "#{@gcs_upload_url}/b/#{bucket}/o",
          params: [uploadType: "media", name: object_name],
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", content_type},
            {"x-goog-meta-adk-metadata", Jason.encode!(metadata)}
          ],
          body: body
        )

      case resp.status do
        200 -> {:ok, version}
        s -> {:error, {:gcs_upload_failed, s, resp.body}}
      end
    end
  end

  @impl true
  def load(app_name, user_id, session_id, filename, opts \\ []) do
    bucket = Keyword.fetch!(opts, :bucket)

    with {:ok, token} <- get_access_token(opts) do
      version = Keyword.get(opts, :version)

      object_name =
        if version do
          object_path(app_name, user_id, session_id, filename, version)
        else
          # Find latest version
          case list_versions(bucket, token, app_name, user_id, session_id, filename) do
            {:ok, []} -> :not_found
            {:ok, versions} -> object_path(app_name, user_id, session_id, filename, Enum.max(versions))
            err -> err
          end
        end

      case object_name do
        :not_found ->
          :not_found

        {:error, _} = err ->
          err

        name ->
          resp =
            Req.get!(
              "#{@gcs_api_url}/b/#{bucket}/o/#{URI.encode(name, &URI.char_unreserved?/1)}",
              params: [alt: "media"],
              headers: [{"authorization", "Bearer #{token}"}]
            )

          case resp.status do
            200 ->
              content_type =
                resp.headers
                |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
                |> case do
                  {_, v} -> v
                  nil -> "application/octet-stream"
                end

              {:ok, %{data: resp.body, content_type: content_type, metadata: %{}}}

            404 ->
              :not_found

            s ->
              {:error, {:gcs_load_failed, s, resp.body}}
          end
      end
    end
  end

  @impl true
  def list(app_name, user_id, session_id, opts \\ []) do
    bucket = Keyword.fetch!(opts, :bucket)

    with {:ok, token} <- get_access_token(opts) do
      prefix = "#{app_name}/#{user_id}/#{session_id}/"

      resp =
        Req.get!(
          "#{@gcs_api_url}/b/#{bucket}/o",
          params: [prefix: prefix, delimiter: "/"],
          headers: [{"authorization", "Bearer #{token}"}]
        )

      case resp.status do
        200 ->
          prefixes = get_in(resp.body, ["prefixes"]) || []

          filenames =
            prefixes
            |> Enum.map(fn p ->
              p
              |> String.trim_leading(prefix)
              |> String.trim_trailing("/")
            end)
            |> Enum.sort()

          {:ok, filenames}

        s ->
          {:error, {:gcs_list_failed, s, resp.body}}
      end
    end
  end

  @impl true
  def delete(app_name, user_id, session_id, filename, opts \\ []) do
    bucket = Keyword.fetch!(opts, :bucket)

    with {:ok, token} <- get_access_token(opts),
         {:ok, versions} <- list_versions(bucket, token, app_name, user_id, session_id, filename) do
      Enum.each(versions, fn v ->
        name = object_path(app_name, user_id, session_id, filename, v)

        Req.delete!(
          "#{@gcs_api_url}/b/#{bucket}/o/#{URI.encode(name, &URI.char_unreserved?/1)}",
          headers: [{"authorization", "Bearer #{token}"}]
        )
      end)

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp object_path(app, user, session, filename, version) do
    "#{app}/#{user}/#{session}/#{filename}/v#{version}"
  end

  defp list_versions(bucket, token, app, user, session, filename) do
    prefix = "#{app}/#{user}/#{session}/#{filename}/v"

    resp =
      Req.get!(
        "#{@gcs_api_url}/b/#{bucket}/o",
        params: [prefix: prefix],
        headers: [{"authorization", "Bearer #{token}"}]
      )

    case resp.status do
      200 ->
        items = resp.body["items"] || []

        versions =
          items
          |> Enum.map(fn item ->
            item["name"]
            |> String.split("/v")
            |> List.last()
            |> String.to_integer()
          end)
          |> Enum.sort()

        {:ok, versions}

      s ->
        {:error, {:gcs_versions_failed, s, resp.body}}
    end
  end

  defp next_version(bucket, token, app, user, session, filename) do
    case list_versions(bucket, token, app, user, session, filename) do
      {:ok, []} -> {:ok, 0}
      {:ok, versions} -> {:ok, Enum.max(versions) + 1}
      err -> err
    end
  end

  defp get_access_token(opts) do
    creds_file =
      Keyword.get(opts, :credentials_file) ||
        System.get_env("GOOGLE_APPLICATION_CREDENTIALS")

    cond do
      creds_file && File.exists?(creds_file) ->
        get_sa_token(creds_file)

      true ->
        # Try metadata server (Compute Engine / Cloud Run)
        get_metadata_token()
    end
  end

  defp get_sa_token(creds_file) do
    with {:ok, json} <- File.read(creds_file),
         {:ok, creds} <- Jason.decode(json) do
      now = System.system_time(:second)

      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)

      claims =
        Base.url_encode64(
          Jason.encode!(%{
            "iss" => creds["client_email"],
            "scope" => Enum.join(@scopes, " "),
            "aud" => "https://oauth2.googleapis.com/token",
            "iat" => now,
            "exp" => now + 3600
          }),
          padding: false
        )

      signing_input = "#{header}.#{claims}"

      # Decode the private key and sign
      [entry] = :public_key.pem_decode(creds["private_key"])
      key = :public_key.pem_entry_decode(entry)
      signature = :public_key.sign(signing_input, :sha256, key)
      sig_b64 = Base.url_encode64(signature, padding: false)

      jwt = "#{signing_input}.#{sig_b64}"

      resp =
        Req.post!("https://oauth2.googleapis.com/token",
          form: [
            grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
            assertion: jwt
          ]
        )

      case resp.status do
        200 -> {:ok, resp.body["access_token"]}
        s -> {:error, {:token_error, s, resp.body}}
      end
    end
  end

  defp get_metadata_token do
    resp =
      Req.get!("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
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
