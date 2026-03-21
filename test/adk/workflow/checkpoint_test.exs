defmodule ADK.Workflow.CheckpointTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow.Checkpoint
  alias ADK.Workflow.Checkpoint.EtsStore

  describe "Checkpoint.new/4" do
    test "creates a checkpoint map" do
      cp = Checkpoint.new("wf-1", :node_a, :completed, "output data")
      assert cp.workflow_id == "wf-1"
      assert cp.node_id == :node_a
      assert cp.status == :completed
      assert cp.output == "output data"
      assert %DateTime{} = cp.timestamp
    end

    test "defaults output to nil" do
      cp = Checkpoint.new("wf-2", :node_b, :running)
      assert cp.output == nil
    end
  end

  describe "EtsStore" do
    setup do
      EtsStore.init()
      workflow_id = "test-#{:erlang.unique_integer([:positive])}"
      {:ok, workflow_id: workflow_id}
    end

    test "save and load checkpoint", %{workflow_id: wid} do
      assert :ok = EtsStore.save(wid, :step_1, :completed, "step 1 output")

      assert {:ok, cp} = EtsStore.load(wid, :step_1)
      assert cp.workflow_id == wid
      assert cp.node_id == :step_1
      assert cp.status == :completed
      assert cp.output == "step 1 output"
    end

    test "load returns :not_found for missing checkpoint", %{workflow_id: wid} do
      assert :not_found = EtsStore.load(wid, :nonexistent)
    end

    test "load_all returns all checkpoints for workflow", %{workflow_id: wid} do
      EtsStore.save(wid, :step_1, :completed, "out1")
      EtsStore.save(wid, :step_2, :completed, "out2")
      EtsStore.save(wid, :step_3, :running, nil)

      checkpoints = EtsStore.load_all(wid)
      assert length(checkpoints) == 3
    end

    test "completed_nodes returns only completed", %{workflow_id: wid} do
      EtsStore.save(wid, :step_1, :completed, "out1")
      EtsStore.save(wid, :step_2, :failed, "error")
      EtsStore.save(wid, :step_3, :completed, "out3")

      completed = EtsStore.completed_nodes(wid)
      assert :step_1 in completed
      assert :step_3 in completed
      refute :step_2 in completed
    end

    test "clear removes all checkpoints", %{workflow_id: wid} do
      EtsStore.save(wid, :step_1, :completed, "out1")
      EtsStore.save(wid, :step_2, :completed, "out2")

      assert :ok = EtsStore.clear(wid)
      assert EtsStore.load_all(wid) == []
    end

    test "different workflows are isolated" do
      wid1 = "isolation-1-#{:erlang.unique_integer([:positive])}"
      wid2 = "isolation-2-#{:erlang.unique_integer([:positive])}"

      EtsStore.save(wid1, :step_a, :completed, "a")
      EtsStore.save(wid2, :step_b, :completed, "b")

      assert length(EtsStore.load_all(wid1)) == 1
      assert length(EtsStore.load_all(wid2)) == 1

      EtsStore.clear(wid1)
      assert EtsStore.load_all(wid1) == []
      assert length(EtsStore.load_all(wid2)) == 1
    end

    test "save overwrites existing checkpoint", %{workflow_id: wid} do
      EtsStore.save(wid, :step_1, :running, nil)
      EtsStore.save(wid, :step_1, :completed, "done")

      assert {:ok, cp} = EtsStore.load(wid, :step_1)
      assert cp.status == :completed
      assert cp.output == "done"
    end
  end

  describe "EctoStore" do
    test "raises when called without repo" do
      assert_raise RuntimeError, ~r/requires a repo/, fn ->
        ADK.Workflow.Checkpoint.EctoStore.save("wf", :node, :completed, nil)
      end
    end

    test "module compiles and is loadable" do
      assert {:module, ADK.Workflow.Checkpoint.EctoStore} =
               Code.ensure_loaded(ADK.Workflow.Checkpoint.EctoStore)
    end

    test "save_with_repo function exists" do
      Code.ensure_loaded!(ADK.Workflow.Checkpoint.EctoStore)
      assert function_exported?(ADK.Workflow.Checkpoint.EctoStore, :save_with_repo, 5)
    end
  end
end
