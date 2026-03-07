defmodule ADK.Session.Store.InMemoryTest do
  use ExUnit.Case, async: false

  alias ADK.Session.Store.InMemory

  setup do
    # Start a fresh ETS-backed store for each test
    case GenServer.whereis(InMemory) do
      nil -> InMemory.start_link([])
      pid -> 
        :ets.delete_all_objects(InMemory)
        {:ok, pid}
    end

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

  test "save and load" do
    session = make_session()
    assert :ok = InMemory.save(session)

    {:ok, data} = InMemory.load("test_app", "user1", "sess1")
    assert data.id == "sess1"
    assert data.state == %{counter: 42}
  end

  test "load returns error for missing session" do
    assert {:error, :not_found} = InMemory.load("nope", "nope", "nope")
  end

  test "delete removes session" do
    session = make_session()
    InMemory.save(session)
    assert :ok = InMemory.delete("test_app", "user1", "sess1")
    assert {:error, :not_found} = InMemory.load("test_app", "user1", "sess1")
  end

  test "list returns session ids for user" do
    InMemory.save(make_session(id: "s1"))
    InMemory.save(make_session(id: "s2"))
    InMemory.save(make_session(id: "s3", user_id: "other"))

    ids = InMemory.list("test_app", "user1")
    assert Enum.sort(ids) == ["s1", "s2"]
  end

  test "save with events serializes them" do
    event = ADK.Event.new(%{author: "user", content: %{parts: [%{text: "hello"}]}})
    session = make_session(events: [event])
    InMemory.save(session)

    {:ok, data} = InMemory.load("test_app", "user1", "sess1")
    assert length(data.events) == 1
    assert hd(data.events).author == "user"
  end
end
