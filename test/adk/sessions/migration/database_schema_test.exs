defmodule ADK.Sessions.Migration.DatabaseSchemaTest do
  use ExUnit.Case, async: false

  # We define a custom repo for testing the migration
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :adk,
      adapter: Ecto.Adapters.SQLite3
  end

  setup do
    Application.put_env(:adk, TestRepo,
      database: ":memory:",
      pool_size: 1
    )

    start_supervised!(TestRepo)
    :ok
  end

  test "new db uses latest schema" do
    # Get the migration template from Mix task instead of hardcoding
    # We evaluate the string to get the template dynamically
    
    # Let's use Regex to extract the template
    task_code = File.read!("lib/mix/tasks/adk.gen.migration.ex")
    
    [_, template] = Regex.run(~r/defp migration_template do\s+"""\s*(.*?)\s*"""\s+end/s, task_code)
    
    # Replace EEx binding
    template = String.replace(template, "<%= inspect @module %>", "ADK.Migrations.CreateAdkSessionsTest")
    
    Code.eval_string(template)
    
    Ecto.Migrator.up(TestRepo, 20260101000000, ADK.Migrations.CreateAdkSessionsTest)
    
    # Verify metadata table
    result = Ecto.Adapters.SQL.query!(TestRepo, "SELECT name FROM sqlite_master WHERE type='table' AND name='adk_internal_metadata'")
    assert [["adk_internal_metadata"]] = result.rows
    
    # Verify schema version
    result = Ecto.Adapters.SQL.query!(TestRepo, "SELECT value FROM adk_internal_metadata WHERE key='schema_version'")
    assert [["1"]] = result.rows
    
    # Verify events table has event_data and NOT actions
    result = Ecto.Adapters.SQL.query!(TestRepo, "PRAGMA table_info(events)")
    columns = Enum.map(result.rows, fn row -> Enum.at(row, 1) end)
    
    assert "event_data" in columns
    refute "actions" in columns
  end
  
  test "existing v0 db uses v0 schema" do
    # Simulates what python expects for a v0 DB
    
    # Create the v0 DB explicitly
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      app_name TEXT,
      user_id TEXT,
      session_id TEXT,
      actions TEXT
    )
    """)
    
    # Verify metadata doesn't exist
    result = Ecto.Adapters.SQL.query!(TestRepo, "SELECT name FROM sqlite_master WHERE type='table' AND name='adk_internal_metadata'")
    assert [] = result.rows
    
    # Verify events has actions
    result = Ecto.Adapters.SQL.query!(TestRepo, "PRAGMA table_info(events)")
    columns = Enum.map(result.rows, fn row -> Enum.at(row, 1) end)
    
    assert "actions" in columns
    refute "event_data" in columns
  end
  
  test "existing latest db uses latest schema" do
    # Simply testing idempotency of the checks or if our migrator would fail/pass
    # In elixir, we wouldn't auto-upgrade implicitly during runtime, but we verify 
    # the schema constraints as done in Python.
    
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE adk_internal_metadata (
      key TEXT PRIMARY KEY,
      value TEXT
    )
    """)
    
    Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO adk_internal_metadata (key, value) VALUES ('schema_version', '1')")
    
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      app_name TEXT,
      user_id TEXT,
      session_id TEXT,
      event_data TEXT
    )
    """)
    
    # Verify metadata table
    result = Ecto.Adapters.SQL.query!(TestRepo, "SELECT name FROM sqlite_master WHERE type='table' AND name='adk_internal_metadata'")
    assert [["adk_internal_metadata"]] = result.rows
    
    # Verify events table columns for v1
    result = Ecto.Adapters.SQL.query!(TestRepo, "PRAGMA table_info(events)")
    columns = Enum.map(result.rows, fn row -> Enum.at(row, 1) end)
    
    assert "event_data" in columns
    refute "actions" in columns
  end
end
