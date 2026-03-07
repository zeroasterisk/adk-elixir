defmodule ADK.Session.Store.EctoTest do
  use ExUnit.Case, async: false

  alias ADK.Session.Store.Ecto, as: EctoStore
  alias ADK.Session.Store.Ecto.Schema

  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :adk,
      adapter: Ecto.Adapters.SQLite3
  end

  setup_all do
    # Configure the test repo
    Application.put_env(:adk, TestRepo,
      database: ":memory:",
      pool_size: 1
    )

    Application.put_env(:adk, EctoStore, repo: TestRepo)

    {:ok, _} = TestRepo.start_link()

    # Run migration inline
    TestRepo.query!("""
    CREATE TABLE adk_sessions (
      app_name TEXT NOT NULL,
      user_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      state TEXT DEFAULT '{}',
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (app_name, user_id, session_id)
    )
    """)

    :ok
  end

  setup do
    # Clean table between tests
    TestRepo.delete_all(Schema)
    :ok
  end

  test "save and load a session" do
    session = %ADK.Session{
      id: "sess1",
      app_name: "app1",
      user_id: "user1",
      state: %{"counter" => 42, "name" => "test"},
      events: []
    }

    assert :ok = EctoStore.save(session)

    assert {:ok, loaded} = EctoStore.load("app1", "user1", "sess1")
    assert loaded[:id] == "sess1"
    assert loaded[:app_name] == "app1"
    assert loaded[:user_id] == "user1"
    assert loaded[:state] == %{"counter" => 42, "name" => "test"}
  end

  test "load returns error for missing session" do
    assert {:error, :not_found} = EctoStore.load("nope", "nope", "nope")
  end

  test "save updates existing session" do
    session = %ADK.Session{
      id: "sess1",
      app_name: "app1",
      user_id: "user1",
      state: %{"v" => 1},
      events: []
    }

    assert :ok = EctoStore.save(session)

    updated = %{session | state: %{"v" => 2}}
    assert :ok = EctoStore.save(updated)

    assert {:ok, loaded} = EctoStore.load("app1", "user1", "sess1")
    assert loaded[:state] == %{"v" => 2}
  end

  test "delete removes a session" do
    session = %ADK.Session{
      id: "sess1",
      app_name: "app1",
      user_id: "user1",
      state: %{},
      events: []
    }

    EctoStore.save(session)
    assert :ok = EctoStore.delete("app1", "user1", "sess1")
    assert {:error, :not_found} = EctoStore.load("app1", "user1", "sess1")
  end

  test "list returns session ids for app+user" do
    for i <- 1..3 do
      session = %ADK.Session{
        id: "sess#{i}",
        app_name: "app1",
        user_id: "user1",
        state: %{},
        events: []
      }

      EctoStore.save(session)
    end

    # Different user
    EctoStore.save(%ADK.Session{
      id: "other",
      app_name: "app1",
      user_id: "user2",
      state: %{},
      events: []
    })

    ids = EctoStore.list("app1", "user1")
    assert length(ids) == 3
    assert Enum.sort(ids) == ["sess1", "sess2", "sess3"]
  end

  test "state serializes nested maps and lists" do
    session = %ADK.Session{
      id: "sess1",
      app_name: "app1",
      user_id: "user1",
      state: %{
        "nested" => %{"deep" => true},
        "list" => [1, 2, 3],
        "null_val" => nil
      },
      events: []
    }

    assert :ok = EctoStore.save(session)
    assert {:ok, loaded} = EctoStore.load("app1", "user1", "sess1")
    assert loaded[:state]["nested"] == %{"deep" => true}
    assert loaded[:state]["list"] == [1, 2, 3]
    assert loaded[:state]["null_val"] == nil
  end
end
