defmodule ADK.Artifact.Store do
  @moduledoc """
  Behaviour for pluggable artifact storage backends.

  Mirrors Python ADK's `BaseArtifactService`. Artifacts are binary blobs
  (files, images, etc.) attached to a session, keyed by filename with
  versioning support.
  """

  @type artifact :: %{data: binary(), content_type: String.t(), metadata: map()}

  @doc "Save an artifact, returning the new version number."
  @callback save(
              app_name :: String.t(),
              user_id :: String.t(),
              session_id :: String.t(),
              filename :: String.t(),
              artifact :: artifact(),
              opts :: keyword()
            ) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Load an artifact by filename and optional version."
  @callback load(
              app_name :: String.t(),
              user_id :: String.t(),
              session_id :: String.t(),
              filename :: String.t(),
              opts :: keyword()
            ) :: {:ok, artifact()} | :not_found | {:error, term()}

  @doc "List artifact filenames for a session."
  @callback list(
              app_name :: String.t(),
              user_id :: String.t(),
              session_id :: String.t(),
              opts :: keyword()
            ) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Delete an artifact by filename."
  @callback delete(
              app_name :: String.t(),
              user_id :: String.t(),
              session_id :: String.t(),
              filename :: String.t(),
              opts :: keyword()
            ) :: :ok | {:error, term()}
end
