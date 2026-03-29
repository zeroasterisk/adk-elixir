defmodule ADK.Session.Store.SQLiteTest do
  use ExUnit.Case, async: false

  @moduletag :sqlite

  alias ADK.Session.Store.SQLite

  setup do
    # Stop any existing instance
    case GenServer.whereis(SQLite) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, _pid} = SQLite.start_link(db_path: ":memory:")
    :ok
  end

  defp make_session(attrs \\ %{}) do
    %ADK.Session{
      id: attrs[:id] || "sess1",
      app_name: attrs[:app_name] || "test_app",
      user_id: attrs[:user_id] || "user1",
      state: attrs[:state] || %{counter: 42},
      events: attrs[:events] || []
    }
  end

  defp make_event(text, opts \\ []) do
    ADK.Event.new(%{
      author: opts[:author] || "user",
      content: %{parts: [%{text: text}]}
    })
  end

  test "save and load" do
    session = make_session()
    assert :ok = SQLite.save(session)

    {:ok, data} = SQLite.load("test_app", "user1", "sess1")
    assert data.id == "sess1"
    assert data.state == %{counter: 42}
  end

  test "load returns error for missing session" do
    assert {:error, :not_found} = SQLite.load("nope", "nope", "nope")
  end

  test "delete removes session" do
    session = make_session()
    SQLite.save(session)
    assert :ok = SQLite.delete("test_app", "user1", "sess1")
    assert {:error, :not_found} = SQLite.load("test_app", "user1", "sess1")
  end

  test "list returns session ids for user" do
    SQLite.save(make_session(id: "s1"))
    SQLite.save(make_session(id: "s2"))
    SQLite.save(make_session(id: "s3", user_id: "other"))

    ids = SQLite.list("test_app", "user1")
    assert Enum.sort(ids) == ["s1", "s2"]
  end

  test "save with events serializes them" do
    event = make_event("hello world")
    session = make_session(events: [event])
    SQLite.save(session)

    {:ok, data} = SQLite.load("test_app", "user1", "sess1")
    assert length(data.events) == 1
    assert hd(data.events).author == "user"
  end

  test "save replaces events on update" do
    session = make_session(events: [make_event("first")])
    SQLite.save(session)

    updated = make_session(events: [make_event("second"), make_event("third")])
    SQLite.save(updated)

    {:ok, data} = SQLite.load("test_app", "user1", "sess1")
    assert length(data.events) == 2
  end

  test "save updates state on upsert" do
    SQLite.save(make_session(state: %{v: 1}))
    SQLite.save(make_session(state: %{v: 2}))

    {:ok, data} = SQLite.load("test_app", "user1", "sess1")
    assert data.state == %{v: 2}
  end

  # --- FTS5 Search Tests ---

  test "search returns events matching a term" do
    session =
      make_session(
        events: [
          make_event("the quick brown fox"),
          make_event("lazy dog sleeps"),
          make_event("fox jumps over")
        ]
      )

    SQLite.save(session)

    results = SQLite.search("fox")
    assert length(results) == 2
  end

  test "search with app_name filter" do
    SQLite.save(
      make_session(
        app_name: "app1",
        events: [make_event("deploy started")]
      )
    )

    SQLite.save(
      make_session(
        app_name: "app2",
        id: "sess2",
        events: [make_event("deploy finished")]
      )
    )

    results = SQLite.search("deploy", app_name: "app1")
    assert length(results) == 1
    assert hd(results).app_name == "app1"
  end

  test "search with session_id filter" do
    SQLite.save(make_session(id: "s1", events: [make_event("error occurred")]))
    SQLite.save(make_session(id: "s2", events: [make_event("error again")]))

    results = SQLite.search("error", session_id: "s1")
    assert length(results) == 1
    assert hd(results).session_id == "s1"
  end

  test "search with no results returns empty list" do
    SQLite.save(make_session(events: [make_event("hello")]))

    assert [] = SQLite.search("nonexistent_term_xyz")
  end

  test "search_sessions returns distinct session ids" do
    SQLite.save(
      make_session(
        id: "s1",
        events: [make_event("critical error"), make_event("another error")]
      )
    )

    SQLite.save(make_session(id: "s2", events: [make_event("all good")]))
    SQLite.save(make_session(id: "s3", events: [make_event("error found")]))

    session_ids = SQLite.search_sessions("error")
    assert Enum.sort(session_ids) == ["s1", "s3"]
  end

  test "search respects limit" do
    events = for i <- 1..10, do: make_event("searchable item #{i}")
    SQLite.save(make_session(events: events))

    results = SQLite.search("searchable", limit: 3)
    assert length(results) == 3
  end

  test "search by author" do
    session =
      make_session(
        events: [
          make_event("user message", author: "user"),
          make_event("agent response", author: "agent")
        ]
      )

    SQLite.save(session)

    # FTS5 searches across all indexed columns including author
    results = SQLite.search("agent")
    assert length(results) >= 1
  end

  test "delete cleans up events and FTS index" do
    SQLite.save(make_session(events: [make_event("findable content")]))
    assert [_] = SQLite.search("findable")

    SQLite.delete("test_app", "user1", "sess1")
    assert [] = SQLite.search("findable")
  end
end
