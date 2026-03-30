defmodule ADK.Policy.HumanApprovalTest do
  use ExUnit.Case, async: true

  alias ADK.Policy.HumanApproval
  alias ADK.Tool.Approval
  alias ADK.Policy

  defp make_tool(name), do: %{name: name, description: "test tool"}

  defp make_ctx,
    do: %ADK.Context{
      invocation_id: "test",
      session_pid: nil,
      agent: nil,
      user_content: %{},
      callbacks: [],
      policies: [],
      plugins: []
    }

  describe "new/1" do
    test "creates struct with defaults" do
      policy = HumanApproval.new(sensitive_tools: ["my_tool"])
      assert policy.sensitive_tools == ["my_tool"]
      assert policy.mode == :cli
      assert policy.timeout == 60_000
    end

    test "accepts :all for sensitive_tools" do
      policy = HumanApproval.new(sensitive_tools: :all)
      assert policy.sensitive_tools == :all
    end

    test "accepts server mode options" do
      policy = HumanApproval.new(sensitive_tools: ["foo"], mode: :server, timeout: 1_000)
      assert policy.mode == :server
      assert policy.timeout == 1_000
    end
  end

  describe "check/4 — non-sensitive tools" do
    test "always allows tools not in the sensitive list" do
      policy = HumanApproval.new(sensitive_tools: ["dangerous"])
      tool = make_tool("safe_tool")
      assert HumanApproval.check(policy, tool, %{}, make_ctx()) == :allow
    end

    test "empty sensitive list allows everything" do
      policy = HumanApproval.new(sensitive_tools: [])
      assert HumanApproval.check(policy, make_tool("any_tool"), %{}, make_ctx()) == :allow
    end
  end

  describe "check/4 — :all sensitive tools" do
    test "intercepts all tools when sensitive_tools: :all" do
      policy =
        HumanApproval.new(
          sensitive_tools: :all,
          mode: :cli,
          prompt_fn: fn _ -> :allow end
        )

      tool = make_tool("any_tool")
      assert HumanApproval.check(policy, tool, %{}, make_ctx()) == :allow
    end
  end

  describe "check/4 — CLI mode with custom prompt_fn" do
    test "calls prompt_fn and returns :allow when approved" do
      policy =
        HumanApproval.new(
          sensitive_tools: ["dangerous"],
          mode: :cli,
          prompt_fn: fn _ctx -> :allow end
        )

      assert HumanApproval.check(policy, make_tool("dangerous"), %{}, make_ctx()) == :allow
    end

    test "calls prompt_fn and returns {:deny, reason} when denied" do
      policy =
        HumanApproval.new(
          sensitive_tools: ["dangerous"],
          mode: :cli,
          prompt_fn: fn _ctx -> {:deny, "Not today"} end
        )

      assert HumanApproval.check(policy, make_tool("dangerous"), %{}, make_ctx()) ==
               {:deny, "Not today"}
    end

    test "non-sensitive tools skip prompt_fn entirely" do
      called = :counters.new(1, [:atomics])

      policy =
        HumanApproval.new(
          sensitive_tools: ["dangerous"],
          mode: :cli,
          prompt_fn: fn _ ->
            :counters.add(called, 1, 1)
            :allow
          end
        )

      HumanApproval.check(policy, make_tool("safe"), %{}, make_ctx())
      assert :counters.get(called, 1) == 0
    end
  end

  describe "check/4 — server mode" do
    setup do
      {:ok, server} = start_supervised({Approval, name: nil})
      %{server: server}
    end

    test "blocks and returns :allow when approved", %{server: server} do
      policy =
        HumanApproval.new(
          sensitive_tools: ["shell_command"],
          mode: :server,
          server: server,
          timeout: 5_000
        )

      # Approve from a separate process after a short delay
      task =
        Task.async(fn ->
          HumanApproval.check(policy, make_tool("shell_command"), %{}, make_ctx())
        end)

      # Give the task time to register + subscribe
      Process.sleep(100)
      [%{id: request_id}] = Approval.list_pending(server)
      Approval.approve(server, request_id)

      assert Task.await(task, 5_000) == :allow
    end

    test "blocks and returns {:deny, reason} when denied", %{server: server} do
      policy =
        HumanApproval.new(
          sensitive_tools: ["delete_file"],
          mode: :server,
          server: server,
          timeout: 5_000
        )

      task =
        Task.async(fn ->
          HumanApproval.check(policy, make_tool("delete_file"), %{}, make_ctx())
        end)

      Process.sleep(100)
      [%{id: request_id}] = Approval.list_pending(server)
      Approval.deny(server, request_id, "Admin refused")

      assert Task.await(task, 5_000) == {:deny, "Admin refused"}
    end

    test "times out and denies when no decision arrives", %{server: server} do
      policy =
        HumanApproval.new(
          sensitive_tools: ["slow_tool"],
          mode: :server,
          server: server,
          timeout: 200
        )

      result = HumanApproval.check(policy, make_tool("slow_tool"), %{}, make_ctx())
      assert {:deny, _reason} = result
      assert String.contains?(elem(result, 1), "timed out")
    end
  end

  describe "ADK.Policy.check_tool_authorization — struct policy integration" do
    test "struct policy participates in the policy chain" do
      policy =
        HumanApproval.new(
          sensitive_tools: ["bad_tool"],
          mode: :cli,
          prompt_fn: fn _ -> {:deny, "Blocked by HITL"} end
        )

      # check_tool_authorization accepts struct policies
      result = Policy.check_tool_authorization([policy], make_tool("bad_tool"), %{}, make_ctx())
      assert result == {:deny, "Blocked by HITL"}
    end

    test "struct policy allows non-sensitive tools" do
      policy =
        HumanApproval.new(
          sensitive_tools: ["bad_tool"],
          mode: :cli,
          prompt_fn: fn _ -> {:deny, "Should not be called"} end
        )

      result = Policy.check_tool_authorization([policy], make_tool("safe_tool"), %{}, make_ctx())
      assert result == :allow
    end

    test "struct policy composes with module policies — first deny wins" do
      defmodule DenyAllPolicy do
        @behaviour ADK.Policy
        def authorize_tool(_t, _a, _c), do: {:deny, "Module policy denied"}
      end

      hitl_policy =
        HumanApproval.new(
          sensitive_tools: ["safe_tool"],
          mode: :cli,
          prompt_fn: fn _ -> :allow end
        )

      # HITL allows, DenyAllPolicy denies — deny should win
      result =
        Policy.check_tool_authorization(
          [hitl_policy, DenyAllPolicy],
          make_tool("safe_tool"),
          %{},
          make_ctx()
        )

      assert result == {:deny, "Module policy denied"}
    end
  end
end
