defmodule ADK.Session.Store.JsonFileTest do
  use ExUnit.Case, async: false

  alias ADK.Session.Store.JsonFile

  @tmp_path "test/tmp/json_store"

  setup do
    Application.put_env(:adk, :json_store_path, @tmp_path)
    File.rm_rf!(@tmp_path)

    on_exit(fn ->
      File.rm_rf!(@tmp_path)
      Application.delete_env(:adk, :json_store_path)
    end)

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

  test "save creates JSON file and load reads it" do
    session = make_session()
    assert :ok = JsonFile.save(session)
    assert File.exists?(Path.join([@tmp_path, "test_app", "user1", "sess1.json"]))

    {:ok, data} = JsonFile.load("test_app", "user1", "sess1")
    assert data.id == "sess1"
    assert data.state.counter == 42
  end

  test "load returns error for missing session" do
    assert {:error, :not_found} = JsonFile.load("nope", "nope", "nope")
  end

  test "delete removes file" do
    session = make_session()
    JsonFile.save(session)
    assert :ok = JsonFile.delete("test_app", "user1", "sess1")
    assert {:error, :not_found} = JsonFile.load("test_app", "user1", "sess1")
  end

  test "list returns session ids" do
    JsonFile.save(make_session(id: "s1"))
    JsonFile.save(make_session(id: "s2"))
    JsonFile.save(make_session(id: "s3", user_id: "other"))

    ids = JsonFile.list("test_app", "user1")
    assert Enum.sort(ids) == ["s1", "s2"]
  end

  test "save with events round-trips through JSON" do
    event = ADK.Event.new(%{author: "user", content: %{parts: [%{text: "hello"}]}})
    session = make_session(events: [event])
    JsonFile.save(session)

    {:ok, data} = JsonFile.load("test_app", "user1", "sess1")
    assert length(data.events) == 1
  end
end
