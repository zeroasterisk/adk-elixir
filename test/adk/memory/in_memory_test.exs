defmodule ADK.Memory.InMemoryTest do
  use ExUnit.Case, async: false

  alias ADK.Memory.{InMemory, Entry}

  setup do
    # InMemory is started by the application supervision tree
    # Clear any existing data
    InMemory.clear("test_app", "user1")
    :ok
  end

  describe "add/3 and search/4" do
    test "stores and retrieves entries by keyword match" do
      entries = [
        Entry.new(content: "User prefers dark mode for the UI"),
        Entry.new(content: "User lives in Berlin, Germany"),
        Entry.new(content: "User likes coffee with milk")
      ]

      assert :ok = InMemory.add("test_app", "user1", entries)

      {:ok, results} = InMemory.search("test_app", "user1", "dark mode")
      assert length(results) >= 1
      assert hd(results).content =~ "dark mode"
    end

    test "returns empty list when no matches" do
      InMemory.add("test_app", "user1", [Entry.new(content: "hello world")])

      {:ok, results} = InMemory.search("test_app", "user1", "zzzznotfound")
      assert results == []
    end

    test "deduplicates by entry ID" do
      entry = Entry.new(content: "duplicate test")
      InMemory.add("test_app", "user1", [entry])
      InMemory.add("test_app", "user1", [entry])

      {:ok, results} = InMemory.search("test_app", "user1", "duplicate")
      assert length(results) == 1
    end

    test "exact substring match ranks higher" do
      InMemory.add("test_app", "user1", [
        Entry.new(content: "The weather in dark places is cold"),
        Entry.new(content: "User prefers dark mode")
      ])

      {:ok, results} = InMemory.search("test_app", "user1", "dark mode")
      # The exact substring match should be first
      assert hd(results).content =~ "dark mode"
    end

    test "respects limit option" do
      entries = for i <- 1..10, do: Entry.new(content: "memory item #{i}")
      InMemory.add("test_app", "user1", entries)

      {:ok, results} = InMemory.search("test_app", "user1", "memory item", limit: 3)
      assert length(results) == 3
    end
  end

  describe "delete/3" do
    test "removes a specific entry" do
      entry = Entry.new(content: "to be deleted")
      InMemory.add("test_app", "user1", [entry])
      InMemory.delete("test_app", "user1", entry.id)

      {:ok, results} = InMemory.search("test_app", "user1", "deleted")
      assert results == []
    end
  end

  describe "clear/2" do
    test "removes all entries for a user scope" do
      InMemory.add("test_app", "user1", [
        Entry.new(content: "entry one"),
        Entry.new(content: "entry two")
      ])

      InMemory.clear("test_app", "user1")

      {:ok, results} = InMemory.search("test_app", "user1", "entry")
      assert results == []
    end
  end

  describe "add_session/4" do
    test "converts events to memory entries" do
      events = [
        %ADK.Event{
          id: "e1",
          invocation_id: "inv1",
          author: "user",
          content: %{text: "What is the weather?"},
          timestamp: DateTime.utc_now()
        },
        %ADK.Event{
          id: "e2",
          invocation_id: "inv1",
          author: "bot",
          content: %{text: "It's sunny in Berlin today."},
          timestamp: DateTime.utc_now()
        }
      ]

      assert :ok = InMemory.add_session("test_app", "user1", "sess1", events)

      {:ok, results} = InMemory.search("test_app", "user1", "weather")
      assert length(results) >= 1
    end

    test "skips events without text content" do
      events = [
        %ADK.Event{id: "e1", invocation_id: "inv1", author: "system", content: nil},
        %ADK.Event{
          id: "e2",
          invocation_id: "inv1",
          author: "user",
          content: %{text: "hello memory"},
          timestamp: DateTime.utc_now()
        }
      ]

      InMemory.add_session("test_app", "user1", "sess2", events)

      {:ok, results} = InMemory.search("test_app", "user1", "memory")
      assert length(results) == 1
    end
  end

  describe "scoping" do
    test "memories are scoped by app and user" do
      InMemory.add("app1", "user1", [Entry.new(content: "app1 user1 secret")])
      InMemory.add("app2", "user1", [Entry.new(content: "app2 user1 data")])

      {:ok, r1} = InMemory.search("app1", "user1", "secret")
      {:ok, r2} = InMemory.search("app2", "user1", "secret")

      assert length(r1) == 1
      assert r2 == []
    end
  end
end
