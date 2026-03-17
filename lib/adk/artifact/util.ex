# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Artifact.Util do
  @moduledoc """
  Utility functions for handling artifact URIs.

  Mirrors Python ADK's `artifact_util` module — provides parsing,
  construction, and detection of artifact URI references.
  """

  @type parsed_artifact_uri :: %{
          app_name: String.t(),
          user_id: String.t(),
          session_id: String.t() | nil,
          filename: String.t(),
          version: non_neg_integer()
        }

  # artifact://apps/{app}/users/{user}/sessions/{session}/artifacts/{file}/versions/{ver}
  @session_scoped_re ~r"^artifact://apps/([^/]+)/users/([^/]+)/sessions/([^/]+)/artifacts/([^/]+)/versions/(\d+)$"

  # artifact://apps/{app}/users/{user}/artifacts/{file}/versions/{ver}
  @user_scoped_re ~r"^artifact://apps/([^/]+)/users/([^/]+)/artifacts/([^/]+)/versions/(\d+)$"

  @doc """
  Parses an artifact URI into its components.

  Returns a map with `:app_name`, `:user_id`, `:session_id` (nil for
  user-scoped), `:filename`, and `:version`, or `nil` if the URI is invalid.
  """
  @spec parse_artifact_uri(String.t()) :: parsed_artifact_uri() | nil
  def parse_artifact_uri(uri) when is_binary(uri) do
    cond do
      not String.starts_with?(uri, "artifact://") ->
        nil

      match = Regex.run(@session_scoped_re, uri) ->
        [_, app, user, session, file, ver] = match

        %{
          app_name: app,
          user_id: user,
          session_id: session,
          filename: file,
          version: String.to_integer(ver)
        }

      match = Regex.run(@user_scoped_re, uri) ->
        [_, app, user, file, ver] = match

        %{
          app_name: app,
          user_id: user,
          session_id: nil,
          filename: file,
          version: String.to_integer(ver)
        }

      true ->
        nil
    end
  end

  def parse_artifact_uri(_), do: nil

  @doc """
  Constructs an artifact URI from components.

  ## Options

    * `:session_id` — when provided, produces a session-scoped URI;
      otherwise produces a user-scoped URI.
  """
  @spec get_artifact_uri(
          app_name :: String.t(),
          user_id :: String.t(),
          filename :: String.t(),
          version :: non_neg_integer(),
          keyword()
        ) :: String.t()
  def get_artifact_uri(app_name, user_id, filename, version, opts \\ []) do
    case Keyword.get(opts, :session_id) do
      nil ->
        "artifact://apps/#{app_name}/users/#{user_id}/artifacts/#{filename}/versions/#{version}"

      session_id ->
        "artifact://apps/#{app_name}/users/#{user_id}/sessions/#{session_id}/artifacts/#{filename}/versions/#{version}"
    end
  end

  @doc """
  Checks whether a content part is an artifact reference.

  A part is an artifact reference when it has `file_data` with a `file_uri`
  starting with `"artifact://"`.
  """
  @spec is_artifact_ref(map()) :: boolean()
  def is_artifact_ref(%{"file_data" => %{"file_uri" => uri}}) when is_binary(uri) do
    String.starts_with?(uri, "artifact://")
  end

  def is_artifact_ref(_), do: false
end
