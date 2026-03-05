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
