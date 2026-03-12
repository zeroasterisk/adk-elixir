defmodule ADK.Tool.ApprovalTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.Approval

  setup do
    {:ok, server} = start_supervised({Approval, name: nil})
    %{server: server}
  end

  describe "register/3" do
    test "returns a request_id and request map", %{server: server} do
      {request_id, request} = Approval.register(server, "shell_command", %{"command" => "ls"})
      assert String.starts_with?(request_id, "approval-")
      assert request.tool_name == "shell_command"
      assert request.args == %{"command" => "ls"}
      assert %DateTime{} = request.requested_at
    end
  end

  describe "list_pending/1" do
    test "returns empty list when no requests", %{server: server} do
      assert Approval.list_pending(server) == []
    end

    test "lists registered requests", %{server: server} do
      {_id1, _} = Approval.register(server, "tool_a", %{})
      {_id2, _} = Approval.register(server, "tool_b", %{"key" => "val"})
      pending = Approval.list_pending(server)
      assert length(pending) == 2
      names = Enum.map(pending, & &1.tool_name)
      assert "tool_a" in names
      assert "tool_b" in names
    end
  end

  describe "approve/2" do
    test "resolves await with :allow", %{server: server} do
      {request_id, _} = Approval.register(server, "my_tool", %{})

      task =
        Task.async(fn ->
          Approval.await(server, request_id, 5_000)
        end)

      # Give the task time to subscribe
      Process.sleep(50)
      :ok = Approval.approve(server, request_id)

      assert Task.await(task, 5_000) == :allow
    end

    test "removes request from pending after approval", %{server: server} do
      {request_id, _} = Approval.register(server, "my_tool", %{})

      task = Task.async(fn -> Approval.await(server, request_id, 5_000) end)
      Process.sleep(50)
      Approval.approve(server, request_id)
      Task.await(task, 5_000)

      assert Approval.list_pending(server) == []
    end
  end

  describe "deny/3" do
    test "resolves await with {:deny, reason}", %{server: server} do
      {request_id, _} = Approval.register(server, "my_tool", %{})

      task = Task.async(fn -> Approval.await(server, request_id, 5_000) end)
      Process.sleep(50)
      :ok = Approval.deny(server, request_id, "Rejected by test")

      assert Task.await(task, 5_000) == {:deny, "Rejected by test"}
    end

    test "uses default reason when not specified", %{server: server} do
      {request_id, _} = Approval.register(server, "my_tool", %{})

      task = Task.async(fn -> Approval.await(server, request_id, 5_000) end)
      Process.sleep(50)
      Approval.deny(server, request_id)

      assert {:deny, "User denied"} = Task.await(task, 5_000)
    end
  end

  describe "await/3 timeout" do
    test "returns {:deny, timeout reason} when no decision arrives", %{server: server} do
      {request_id, _} = Approval.register(server, "slow_tool", %{})
      result = Approval.await(server, request_id, 100)
      assert {:deny, "Approval timed out after 0 seconds"} = result
    end
  end

  describe "approve/2 with non-existent request" do
    test "returns {:error, :not_found}", %{server: server} do
      assert {:error, :not_found} = Approval.approve(server, "nonexistent-id")
    end
  end
end
