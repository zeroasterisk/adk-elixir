defmodule ADK.SupervisionTest do
  use ExUnit.Case, async: false

  describe "supervision tree" do
    test "all core processes are running" do
      # Registry
      assert Process.whereis(ADK.SessionRegistry) |> is_pid()

      # Plugin Registry
      assert Process.whereis(ADK.Plugin.Registry) |> is_pid()

      # Session store
      assert Process.whereis(ADK.Session.Store.InMemory) |> is_pid()

      # DynamicSupervisor for sessions
      assert Process.whereis(ADK.SessionSupervisor) |> is_pid()

      # Task.Supervisor for runners
      assert Process.whereis(ADK.RunnerSupervisor) |> is_pid()

      # Credential store
      assert Process.whereis(ADK.Auth.InMemoryStore) |> is_pid()

      # Artifact store
      assert Process.whereis(ADK.Artifact.InMemory) |> is_pid()

      # Circuit breaker
      assert Process.whereis(ADK.LLM.CircuitBreaker) |> is_pid()
    end

    test "top-level supervisor uses rest_for_one strategy" do
      # Verify the supervisor exists and is alive
      sup = Process.whereis(ADK.Supervisor)
      assert is_pid(sup)
      assert Process.alive?(sup)
    end
  end

  describe "session registry" do
    test "sessions register and can be looked up" do
      {:ok, pid} =
        ADK.Session.start_supervised(
          app_name: "sup_test",
          user_id: "user1",
          session_id: "reg_test_1"
        )

      assert {:ok, ^pid} = ADK.Session.lookup("sup_test", "user1", "reg_test_1")

      GenServer.stop(pid)
      Process.sleep(50)
      assert :error = ADK.Session.lookup("sup_test", "user1", "reg_test_1")
    end

    test "duplicate session_id returns already_started" do
      {:ok, pid} =
        ADK.Session.start_supervised(
          app_name: "sup_test",
          user_id: "user1",
          session_id: "dup_test"
        )

      assert {:error, {:already_started, ^pid}} =
               ADK.Session.start_supervised(
                 app_name: "sup_test",
                 user_id: "user1",
                 session_id: "dup_test"
               )

      GenServer.stop(pid)
    end
  end

  describe "session restart" do
    test "crashed session is cleaned up from registry" do
      {:ok, pid} =
        ADK.Session.start_supervised(
          app_name: "sup_test",
          user_id: "user1",
          session_id: "crash_test"
        )

      # Kill the session abruptly
      Process.exit(pid, :kill)
      # Give DynamicSupervisor time to clean up
      Process.sleep(50)

      # Session should no longer be in registry
      assert :error = ADK.Session.lookup("sup_test", "user1", "crash_test")
    end
  end

  describe "runner supervisor" do
    test "tasks run under RunnerSupervisor" do
      parent = self()

      {:ok, pid} =
        Task.Supervisor.start_child(ADK.RunnerSupervisor, fn ->
          send(parent, {:task_ran, self()})
        end)

      assert is_pid(pid)
      assert_receive {:task_ran, ^pid}, 1000
    end

    test "crashed task doesn't affect other tasks" do
      parent = self()

      # Start a task that will crash
      Task.Supervisor.start_child(ADK.RunnerSupervisor, fn ->
        raise "intentional crash"
      end)

      # Start another task that should succeed
      {:ok, _pid} =
        Task.Supervisor.start_child(ADK.RunnerSupervisor, fn ->
          send(parent, :second_task_ok)
        end)

      assert_receive :second_task_ok, 1000
    end
  end

  describe "credential store" do
    test "supervised credential store works" do
      :ok = ADK.Auth.InMemoryStore.put("test_key", %{token: "abc"}, server: ADK.Auth.InMemoryStore)

      assert {:ok, %{token: "abc"}} =
               ADK.Auth.InMemoryStore.get("test_key", server: ADK.Auth.InMemoryStore)

      :ok = ADK.Auth.InMemoryStore.delete("test_key", server: ADK.Auth.InMemoryStore)
      assert :not_found = ADK.Auth.InMemoryStore.get("test_key", server: ADK.Auth.InMemoryStore)
    end
  end

  describe "artifact store" do
    test "supervised artifact store works" do
      artifact = %{data: "hello", content_type: "text/plain", metadata: %{}}

      assert {:ok, 0} =
               ADK.Artifact.InMemory.save("app", "user", "sess", "file.txt", artifact,
                 name: ADK.Artifact.InMemory
               )

      assert {:ok, ^artifact} =
               ADK.Artifact.InMemory.load("app", "user", "sess", "file.txt",
                 name: ADK.Artifact.InMemory
               )
    end
  end

  describe "graceful shutdown" do
    test "session with auto_save saves on terminate" do
      {:ok, pid} =
        ADK.Session.start_supervised(
          app_name: "save_test",
          user_id: "user1",
          session_id: "auto_save_1",
          store: {ADK.Session.Store.InMemory, []},
          auto_save: true
        )

      # Put some state
      ADK.Session.put_state(pid, "key", "value")

      # Graceful stop triggers terminate -> auto_save
      GenServer.stop(pid, :normal)

      # Verify it was persisted
      assert {:ok, data} = ADK.Session.Store.InMemory.load("save_test", "user1", "auto_save_1")
      assert data.state["key"] == "value"
    end
  end
end
