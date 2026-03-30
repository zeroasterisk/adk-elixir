defmodule ADK.Workflow.SagaCompensationTest do
  use ExUnit.Case, async: false
  alias ADK.Workflow
  alias ADK.Context

  setup do
    # Ensure ETS checkpoint store is initialized (executor does this, but good to ensure)
    {:ok, ctx: %Context{invocation_id: "saga-test"}}
  end

  test "saga executes steps sequentially when successful", %{ctx: ctx} do
    # using agent processes to track execution order
    {:ok, tracker} = Agent.start_link(fn -> [] end)

    step1 =
      Workflow.run(
        :step1,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step1_run]))
          "step1_done"
        end,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step1_comp]))
          "step1_rolled_back"
        end
      )

    step2 =
      Workflow.run(
        :step2,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step2_run]))
          "step2_done"
        end,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step2_comp]))
          "step2_rolled_back"
        end
      )

    workflow =
      Workflow.new(
        name: "success_saga",
        edges: [{:START, :step1, :step2, :END}],
        nodes: %{
          step1: step1,
          step2: step2
        }
      )

    events = Workflow.run(workflow, ctx)

    order = Agent.get(tracker, & &1)
    assert order == [:step1_run, :step2_run]

    # check that it didn't error out
    assert Enum.any?(events, fn e -> e.author == "step2" and ADK.Event.text(e) == "step2_done" end)
  end

  test "saga rolls back in reverse order on failure", %{ctx: ctx} do
    {:ok, tracker} = Agent.start_link(fn -> [] end)

    step1 =
      Workflow.run(
        :step1,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step1_run]))
          "step1_done"
        end,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step1_comp]))
          "step1_rolled_back"
        end
      )

    step2 =
      Workflow.run(
        :step2,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step2_run]))
          "step2_done"
        end,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step2_comp]))
          "step2_rolled_back"
        end
      )

    step3 =
      Workflow.run(
        :step3,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step3_run]))
          {:error, :simulated_failure}
        end,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step3_comp]))
          "step3_rolled_back"
        end
      )

    workflow =
      Workflow.new(
        name: "failure_saga",
        edges: [{:START, :step1, :step2, :step3, :END}],
        nodes: %{
          step1: step1,
          step2: step2,
          step3: step3
        }
      )

    events = Workflow.run(workflow, ctx)

    order = Agent.get(tracker, & &1)
    # step3_comp should not be called because step3 failed and didn't complete successfully,
    # or step3 failed, so the history is [step2, step1]. Wait, the executor history has node_id.
    # Actually, the history is updated *after* a node completes successfully.
    # So history will be [:step2, :step1].
    # Rollback will pop [:step2, :step1], invoking step2_comp then step1_comp.
    assert order == [:step1_run, :step2_run, :step3_run, :step2_comp, :step1_comp]

    # Check for error event
    assert Enum.any?(events, fn e ->
             e.author == "workflow" and String.contains?(ADK.Event.text(e), "simulated_failure")
           end)
  end

  test "saga compensation supports different arities", %{ctx: ctx} do
    {:ok, tracker} = Agent.start_link(fn -> [] end)

    step1 =
      Workflow.run(
        :step1,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step1_run]))
          "step1_done"
        end,
        fn ctx ->
          Agent.update(tracker, &(&1 ++ [{:step1_comp, ctx.invocation_id}]))
        end
      )

    step2 =
      Workflow.run(
        :step2,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step2_run]))
          "step2_done"
        end,
        fn node_id, ctx ->
          Agent.update(tracker, &(&1 ++ [{:step2_comp, node_id, ctx.invocation_id}]))
        end
      )

    step3 =
      Workflow.run(
        :step3,
        fn _ctx ->
          Agent.update(tracker, &(&1 ++ [:step3_run]))
          "step3_done"
        end,
        fn node_id, reason, ctx ->
          Agent.update(tracker, &(&1 ++ [{:step3_comp, node_id, reason, ctx.invocation_id}]))
        end
      )

    step4 =
      Workflow.run(:step4, fn _ctx ->
        {:error, :boom}
      end)

    workflow =
      Workflow.new(
        name: "arity_saga",
        edges: [{:START, :step1, :step2, :step3, :step4, :END}],
        nodes: %{
          step1: step1,
          step2: step2,
          step3: step3,
          step4: step4
        }
      )

    Workflow.run(workflow, ctx)

    order = Agent.get(tracker, & &1)

    assert order == [
             :step1_run,
             :step2_run,
             :step3_run,
             {:step3_comp, :step3, {:error, :boom}, ctx.invocation_id},
             {:step2_comp, :step2, ctx.invocation_id},
             {:step1_comp, ctx.invocation_id}
           ]
  end
end
