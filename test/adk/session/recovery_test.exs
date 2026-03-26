defmodule ADK.Session.RecoveryTest do
  use ExUnit.Case, async: false

  alias ADK.Session
  alias ADK.Session.Recovery

  @base_path "/tmp/adk_recovery_test_#{System.unique_integer([:positive])}"

  setup do
    File.rm_rf!(@base_path)
    File.mkdir_p!(@base_path)
    Application.put_env(:adk, :json_store_path, @base_path)

    on_exit(fn ->
      File.rm_rf!(@base_path)
      Application.delete_env(:adk, :json_store_path)
    end)

    store = {ADK.Session.Store.JsonFile, []}
    {:ok, store: store}
  end

  describe "recover/1" do
    test "recovers sessions from store", %{store: store} do
      # Create and save a session
      {:ok, pid} =
        Session.start_supervised(
          app_name: "test_app",
          user_id: "user1",
          session_id: "sess_recover_1",
          store: store,
          auto_save: true
        )

      Session.put_state(pid, "key", "value")
      Session.save(pid)
      GenServer.stop(pid)

      # Wait for process to fully stop
      Process.sleep(50)

      # Now recover
      {:ok, count} = Recovery.recover(store: store)
      assert count == 1

      # Verify session is running again
      assert {:ok, recovered_pid} = Session.lookup("test_app", "user1", "sess_recover_1")
      assert recovered_pid != pid

      # Verify state was restored (keys become atoms after JSON round-trip with keys: :atoms)
      assert Session.get_state(recovered_pid, :key) == "value"

      GenServer.stop(recovered_pid)
    end

    test "skips already running sessions", %{store: store} do
      {:ok, pid} =
        Session.start_supervised(
          app_name: "test_app",
          user_id: "user1",
          session_id: "sess_already_running",
          store: store,
          auto_save: true
        )

      Session.save(pid)

      # Recovery should not crash, should count it as recovered
      {:ok, count} = Recovery.recover(store: store)
      assert count == 1

      GenServer.stop(pid)
    end

    test "applies filter function", %{store: store} do
      # Create two sessions
      for id <- ["sess_a", "sess_b"] do
        {:ok, pid} =
          Session.start_supervised(
            app_name: "test_app",
            user_id: "user1",
            session_id: id,
            store: store,
            auto_save: true
          )

        Session.save(pid)
        GenServer.stop(pid)
        Process.sleep(50)
      end

      # Only recover sess_a
      {:ok, count} =
        Recovery.recover(
          store: store,
          filter: fn meta -> meta[:id] == "sess_a" or meta["id"] == "sess_a" end
        )

      assert count == 1
    end

    test "returns error when store doesn't support list_all" do
      store = {ADK.Session.Store.InMemory, []}
      assert {:error, :list_all_not_supported} = Recovery.recover(store: store)
    end

    test "returns ok with 0 when no sessions to recover", %{store: store} do
      {:ok, count} = Recovery.recover(store: store)
      assert count == 0
    end
  end
end
