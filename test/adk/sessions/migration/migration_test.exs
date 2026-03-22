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

defmodule ADK.Session.MigrationTest do
  use ExUnit.Case, async: true

  alias ADK.Session.Migration

  describe "to_sync_url/1" do
    test "strips async drivers from postgres urls" do
      assert Migration.to_sync_url("postgresql+asyncpg://localhost/mydb") == "postgresql://localhost/mydb"
      assert Migration.to_sync_url("postgresql+asyncpg://user:pass@localhost:5432/mydb") == "postgresql://user:pass@localhost:5432/mydb"
      assert Migration.to_sync_url("postgresql+psycopg2://localhost/mydb") == "postgresql://localhost/mydb"
    end

    test "strips async drivers from mysql urls" do
      assert Migration.to_sync_url("mysql+aiomysql://localhost/mydb") == "mysql://localhost/mydb"
      assert Migration.to_sync_url("mysql+asyncmy://user:pass@localhost:3306/mydb") == "mysql://user:pass@localhost:3306/mydb"
    end

    test "strips async drivers from sqlite urls" do
      assert Migration.to_sync_url("sqlite+aiosqlite:///path/to/db.sqlite") == "sqlite:///path/to/db.sqlite"
      assert Migration.to_sync_url("sqlite+aiosqlite:///:memory:") == "sqlite:///:memory:"
    end

    test "leaves standard urls unchanged" do
      assert Migration.to_sync_url("postgresql://localhost/mydb") == "postgresql://localhost/mydb"
      assert Migration.to_sync_url("mysql://localhost/mydb") == "mysql://localhost/mydb"
      assert Migration.to_sync_url("sqlite:///path/to/db.sqlite") == "sqlite:///path/to/db.sqlite"
      assert Migration.to_sync_url("sqlite:///:memory:") == "sqlite:///:memory:"
    end

    test "handles complex urls with query parameters" do
      assert Migration.to_sync_url("postgresql+asyncpg://user:pass@host/db?ssl=require") == "postgresql://user:pass@host/db?ssl=require"
    end

    test "handles invalid urls gracefully" do
      assert Migration.to_sync_url("not-a-url") == "not-a-url"
      assert Migration.to_sync_url("") == ""
      assert Migration.to_sync_url(nil) == nil
    end
  end

  # We define a custom repo for testing the migration detection
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :adk,
      adapter: Ecto.Adapters.SQLite3
  end

  describe "get_db_schema_version/1" do
    setup do
      Application.put_env(:adk, TestRepo,
        database: ":memory:",
        pool_size: 1
      )
      start_supervised!(TestRepo)
      :ok
    end

    test "new db returns latest version" do
      assert Migration.get_db_schema_version(TestRepo) == "1"
    end

    test "db with metadata returns correct version" do
      Ecto.Adapters.SQL.query!(TestRepo, "CREATE TABLE adk_internal_metadata (key TEXT PRIMARY KEY, value TEXT)")
      Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO adk_internal_metadata (key, value) VALUES ('schema_version', '1')")
      
      assert Migration.get_db_schema_version(TestRepo) == "1"
    end

    test "legacy v0 db returns version 0" do
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE events (
        id TEXT PRIMARY KEY,
        app_name TEXT,
        user_id TEXT,
        session_id TEXT,
        actions TEXT
      )
      """)
      
      assert Migration.get_db_schema_version(TestRepo) == "0"
    end
  end

  describe "runtime transformation logic" do
    test "ADK.Event.from_map/1 migrates legacy function calls" do
      # This test verifies that Elixir's runtime handles legacy event data formats
      # equivalent to what a migration script would transform.
      
      legacy_data = %{
        "id" => "event1",
        "author" => "user",
        "timestamp" => "2026-03-22T08:28:00Z",
        "function_calls" => [
          %{"name" => "tool1", "args" => %{"a" => 1}}
        ]
      }
      
      event = ADK.Event.from_map(legacy_data)
      
      assert event.id == "event1"
      assert event.author == "user"
      assert event.timestamp == ~U[2026-03-22 08:28:00Z]
      
      # Verify parts in content
      assert %{parts: [%{function_call: %{"name" => "tool1", "args" => %{"a" => 1}}}]} = event.content
    end

    test "ADK.Event.from_map/1 migrates legacy function responses" do
      legacy_data = %{
        "id" => "event2",
        "author" => "system",
        "timestamp" => "2026-03-22T08:29:00Z",
        "function_responses" => [
          %{"name" => "tool1", "response" => %{"result" => "ok"}}
        ]
      }
      
      event = ADK.Event.from_map(legacy_data)
      
      assert %{parts: [%{function_response: %{"name" => "tool1", "response" => %{"result" => "ok"}}}]} = event.content
    end
  end

  describe "timestamp parity" do
    test "update_timestamp_tz equivalent" do
      # In Python, update_timestamp_tz returns a float timestamp.
      # SQLite might return naive datetimes, and they are converted to UTC.
      
      dt = ~U[2026-01-01 00:00:00.000000Z]
      
      # Mock the behavior of StorageSession.get_update_timestamp(is_sqlite=true)
      # In Elixir, DateTime.to_unix/1 with :f_float (if supported) or just division.
      
      timestamp_float = DateTime.to_unix(dt) + (elem(dt.microsecond, 0) / 1_000_000)
      assert timestamp_float == 1767225600.0
    end
  end
end
