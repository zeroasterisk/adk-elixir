defmodule ADK.SessionTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, pid} =
      ADK.Session.start_link(
        app_name: "test",
        user_id: "user1",
        session_id: "sess1"
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{pid: pid}
  end

  test "get returns session struct", %{pid: pid} do
    {:ok, session} = ADK.Session.get(pid)
    assert session.id == "sess1"
    assert session.app_name == "test"
    assert session.user_id == "user1"
    assert session.state == %{}
    assert session.events == []
  end

  test "put_state and get_state", %{pid: pid} do
    :ok = ADK.Session.put_state(pid, :counter, 42)
    assert ADK.Session.get_state(pid, :counter) == 42
    assert ADK.Session.get_state(pid, :missing) == nil
  end

  test "append_event stores events", %{pid: pid} do
    event = ADK.Event.new(%{author: "user", content: %{parts: [%{text: "hi"}]}})
    :ok = ADK.Session.append_event(pid, event)

    events = ADK.Session.get_events(pid)
    assert length(events) == 1
    assert hd(events).author == "user"
  end

  test "save persists to store", %{pid: pid} do
    # No store configured, returns error
    assert {:error, :no_store} = ADK.Session.save(pid)
  end

  describe "with InMemory store" do
    setup do
      # Ensure InMemory store is running
      case GenServer.whereis(ADK.Session.Store.InMemory) do
        nil -> ADK.Session.Store.InMemory.start_link([])
        _pid -> :ets.delete_all_objects(ADK.Session.Store.InMemory)
      end

      {:ok, pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "user1",
          session_id: "persist1",
          store: {ADK.Session.Store.InMemory, []}
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      %{store_pid: pid}
    end

    test "save and reload from store", %{store_pid: pid} do
      :ok = ADK.Session.put_state(pid, :foo, "bar")
      :ok = ADK.Session.save(pid)

      # Stop and restart — should load from store
      GenServer.stop(pid)

      {:ok, pid2} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "user1",
          session_id: "persist1",
          store: {ADK.Session.Store.InMemory, []}
        )

      assert ADK.Session.get_state(pid2, :foo) == "bar"
      GenServer.stop(pid2)
    end
  end

  test "append_event applies state delta", %{pid: pid} do
    :ok = ADK.Session.put_state(pid, :a, 1)

    event =
      ADK.Event.new(%{
        author: "agent",
        content: %{parts: [%{text: "done"}]},
        actions: %ADK.EventActions{
          state_delta: %{added: %{b: 2}, changed: %{a: 10}, removed: []}
        }
      })

    :ok = ADK.Session.append_event(pid, event)

    assert ADK.Session.get_state(pid, :a) == 10
    assert ADK.Session.get_state(pid, :b) == 2
  end
end
