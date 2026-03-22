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

defmodule ADK.Session.Migration do
  @moduledoc """
  Utilities for database schema version detection and migration.

  Achieves parity with Python's `google.adk.sessions.migration._schema_check_utils`.
  """

  @schema_version_key "schema_version"
  @schema_version_0 "0"
  @schema_version_1 "1"
  @latest_schema_version @schema_version_1

  @doc """
  Returns the schema version key used in the metadata table.
  """
  def schema_version_key, do: @schema_version_key

  @doc """
  Returns the version string for the v1 JSON schema.
  """
  def schema_version_1_json, do: @schema_version_1

  @doc """
  Detects the schema version of the database.

  Checks for the `adk_internal_metadata` table first, then falls back to inspecting
  the structure of the `events` table.
  """
  def get_db_schema_version(repo) do
    # Since Ecto doesn't have a direct "inspector" like SQLAlchemy,
    # we use SQL queries to check for table and column existence.
    
    # Check for adk_internal_metadata table
    if table_exists?(repo, "adk_internal_metadata") do
      case query_metadata(repo, @schema_version_key) do
        {:ok, version} -> version
        _ -> @latest_schema_version
      end
    else
      # Check for events table structure
      if table_exists?(repo, "events") do
        if column_exists?(repo, "events", "actions") and not column_exists?(repo, "events", "event_data") do
          @schema_version_0
        else
          @latest_schema_version
        end
      else
        @latest_schema_version
      end
    end
  end

  @doc """
  Removes '+driver' from database URLs for compatibility with tools that expect
  a standard scheme.

  Matches the behavior of Python's `to_sync_url`.
  """
  def to_sync_url(url) when is_binary(url) do
    if String.contains?(url, "://") do
      [scheme, rest] = String.split(url, "://", parts: 2)
      if String.contains?(scheme, "+") do
        [dialect, _driver] = String.split(scheme, "+", parts: 2)
        "#{dialect}://#{rest}"
      else
        url
      end
    else
      url
    end
  end

  def to_sync_url(other), do: other

  # --- Helpers ---

  defp table_exists?(repo, table_name) do
    # adapter specific query
    query = case repo.__adapter__() do
      Ecto.Adapters.SQLite3 ->
        "SELECT name FROM sqlite_master WHERE type='table' AND name='#{table_name}'"
      Ecto.Adapters.Postgres ->
        "SELECT table_name FROM information_schema.tables WHERE table_name='#{table_name}'"
      _ ->
        nil
    end

    if query do
      case Ecto.Adapters.SQL.query(repo, query) do
        {:ok, %{rows: [[^table_name]]}} -> true
        _ -> false
      end
    else
      false
    end
  end

  defp column_exists?(repo, table_name, column_name) do
    query = case repo.__adapter__() do
      Ecto.Adapters.SQLite3 ->
        "PRAGMA table_info(#{table_name})"
      Ecto.Adapters.Postgres ->
        "SELECT column_name FROM information_schema.columns WHERE table_name='#{table_name}' AND column_name='#{column_name}'"
      _ ->
        nil
    end

    if query do
      case Ecto.Adapters.SQL.query(repo, query) do
        {:ok, %{rows: rows}} ->
          case repo.__adapter__() do
            Ecto.Adapters.SQLite3 ->
              Enum.any?(rows, fn row -> Enum.at(row, 1) == column_name end)
            Ecto.Adapters.Postgres ->
              Enum.any?(rows, fn row -> Enum.at(row, 0) == column_name end)
            _ -> false
          end
        _ -> false
      end
    else
      false
    end
  end

  defp query_metadata(repo, key) do
    query = "SELECT value FROM adk_internal_metadata WHERE key = '#{key}'"
    case Ecto.Adapters.SQL.query(repo, query) do
      {:ok, %{rows: [[value]]}} -> {:ok, value}
      _ -> :error
    end
  end
end
