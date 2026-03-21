defmodule ADK.Workflow.ExecutorTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow.{Graph, Executor, Checkpoint.EtsStore}

  defp make_agent(name, text \\ nil) do
    text = text || "output from #{name}"

    ADK.Agent.Custom.new(
      name: name,
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(author: name, content: %{"parts" => [%{"text" => text}]})]
      end
    )
  end

  defp make_ctx do
    %ADK.Context{invocation_id: "exec-test"}
  end

  defp build_graph(edges, nodes \\ %{}) do
    expanded =
      Enum.flat_map(edges, fn
        {from, %{} = routes} -> [{from, routes}]
        tuple ->
          elements = Tuple.to_list(tuple)
          case elements do
            [from, to] -> [{from, to}]
            chain -> Enum.chunk_every(chain, 2, 1, :discard) |> Enum.map(fn [a, b] -> {a, b} end)
          end
      end)

    Graph.build(expanded, nodes)
  end

  describe "run/3 — basic traversal" do
    test "single node workflow" do
      agent = make_agent("solo", "solo output")
      graph = build_graph([{:START, :solo, :END}], %{solo: agent})

      events = Executor.run(graph, make_ctx())
      assert length(events) > 0
      assert Enum.any?(events, fn e -> ADK.Event.text(e) == "solo output" end)
    end

    test "empty graph (START → END)" do
      graph = build_graph([{:START, :END}])
      events = Executor.run(graph, make_ctx())
      assert events == []
    end

    test "three-step pipeline" do
      a = make_agent("a", "A")
      b = make_agent("b", "B")
      c = make_agent("c", "C")

      graph = build_graph([{:START, :a, :b, :c, :END}], %{a: a, b: b, c: c})
      events = Executor.run(graph, make_ctx())

      authors = Enum.map(events, & &1.author)
      assert "a" in authors
      assert "b" in authors
      assert "c" in authors
    end
  end

  describe "run/3 — function nodes" do
    test "arity-1 function node (receives ctx)" do
      fn_node = fn _ctx ->
        [ADK.Event.new(author: "fn1", content: %{"parts" => [%{"text" => "from fn1"}]})]
      end

      graph = build_graph([{:START, :processor, :END}], %{processor: fn_node})
      events = Executor.run(graph, make_ctx())
      assert Enum.any?(events, fn e -> ADK.Event.text(e) == "from fn1" end)
    end

    test "arity-0 function node" do
      fn_node = fn ->
        [ADK.Event.new(author: "fn0", content: %{"parts" => [%{"text" => "from fn0"}]})]
      end

      graph = build_graph([{:START, :processor, :END}], %{processor: fn_node})
      events = Executor.run(graph, make_ctx())
      assert Enum.any?(events, fn e -> ADK.Event.text(e) == "from fn0" end)
    end

    test "function returning string" do
      fn_node = fn _ctx -> "plain string" end

      graph = build_graph([{:START, :processor, :END}], %{processor: fn_node})
      events = Executor.run(graph, make_ctx())
      assert Enum.any?(events, fn e -> ADK.Event.text(e) == "plain string" end)
    end
  end

  describe "run/3 — conditional routing" do
    test "routes via event custom_metadata" do
      router = fn _ctx ->
        [
          ADK.Event.new(
            author: "router",
            content: %{"parts" => [%{"text" => "routing"}]},
            custom_metadata: %{"route" => "fast"}
          )
        ]
      end

      slow = make_agent("slow", "slow path")
      fast = make_agent("fast", "fast path")

      graph =
        build_graph(
          [
            {:START, :router},
            {:router, %{"slow" => :slow_handler, "fast" => :fast_handler}},
            {:slow_handler, :END},
            {:fast_handler, :END}
          ],
          %{router: router, slow_handler: slow, fast_handler: fast}
        )

      events = Executor.run(graph, make_ctx())
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "fast path" in texts
      refute "slow path" in texts
    end

    test "routes via output text when no route metadata" do
      router = fn _ctx ->
        [
          ADK.Event.new(
            author: "router",
            content: %{"parts" => [%{"text" => "option_b"}]}
          )
        ]
      end

      a = make_agent("a", "path A")
      b = make_agent("b", "path B")

      graph =
        build_graph(
          [
            {:START, :router},
            {:router, %{"option_a" => :a, "option_b" => :b}},
            {:a, :END},
            {:b, :END}
          ],
          %{router: router, a: a, b: b}
        )

      events = Executor.run(graph, make_ctx())
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "path B" in texts
    end
  end

  describe "run/3 — parallel fan-out" do
    test "executes multiple START targets in parallel" do
      a = make_agent("branch_a", "A result")
      b = make_agent("branch_b", "B result")

      graph =
        build_graph(
          [{:START, :a}, {:START, :b}, {:a, :END}, {:b, :END}],
          %{a: a, b: b}
        )

      events = Executor.run(graph, make_ctx())
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "A result" in texts
      assert "B result" in texts
    end
  end

  describe "run/3 — checkpointing" do
    test "saves checkpoints for completed nodes" do
      agent = make_agent("ckpt_node", "checkpoint me")
      graph = build_graph([{:START, :node, :END}], %{node: agent})

      workflow_id = "test-ckpt-#{:erlang.unique_integer([:positive])}"
      Executor.run(graph, make_ctx(), resume_id: workflow_id)

      # Verify checkpoint was saved
      completed = EtsStore.completed_nodes(workflow_id)
      assert :node in completed
    end

    test "skips completed nodes on resume" do
      # First run — will checkpoint
      call_count = :counters.new(1, [:atomics])

      counting_agent =
        ADK.Agent.Custom.new(
          name: "counter",
          run_fn: fn _agent, _ctx ->
            :counters.add(call_count, 1, 1)
            [ADK.Event.new(author: "counter", content: %{"parts" => [%{"text" => "counted"}]})]
          end
        )

      graph = build_graph([{:START, :counter, :END}], %{counter: counting_agent})
      workflow_id = "test-resume-#{:erlang.unique_integer([:positive])}"

      # First run
      Executor.run(graph, make_ctx(), resume_id: workflow_id)
      assert :counters.get(call_count, 1) == 1

      # Second run with same ID — should skip the node
      Executor.run(graph, make_ctx(), resume_id: workflow_id)
      assert :counters.get(call_count, 1) == 1
    end

    test "clear removes all checkpoints" do
      agent = make_agent("clearable", "clear me")
      graph = build_graph([{:START, :clearable, :END}], %{clearable: agent})

      workflow_id = "test-clear-#{:erlang.unique_integer([:positive])}"
      Executor.run(graph, make_ctx(), resume_id: workflow_id)

      assert EtsStore.completed_nodes(workflow_id) != []

      EtsStore.clear(workflow_id)
      assert EtsStore.completed_nodes(workflow_id) == []
    end
  end

  describe "run/3 — telemetry" do
    test "emits workflow start/stop telemetry" do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "test-wf-#{inspect(ref)}",
        [[:adk, :workflow, :start], [:adk, :workflow, :stop]],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      agent = make_agent("telem_agent", "telemetry test")
      graph = build_graph([{:START, :agent, :END}], %{agent: agent})
      Executor.run(graph, make_ctx())

      assert_receive {:telemetry, [:adk, :workflow, :start], _, %{workflow_id: _}}, 1000
      assert_receive {:telemetry, [:adk, :workflow, :stop], _, %{workflow_id: _}}, 1000

      :telemetry.detach("test-wf-#{inspect(ref)}")
    end

    test "emits node start/stop telemetry" do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "test-node-#{inspect(ref)}",
        [[:adk, :workflow, :node, :start], [:adk, :workflow, :node, :stop]],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      agent = make_agent("node_telem", "node telemetry")
      graph = build_graph([{:START, :agent, :END}], %{agent: agent})
      Executor.run(graph, make_ctx())

      assert_receive {:telemetry, [:adk, :workflow, :node, :start], _, %{node_id: :agent}}, 1000
      assert_receive {:telemetry, [:adk, :workflow, :node, :stop], _, %{node_id: :agent}}, 1000

      :telemetry.detach("test-node-#{inspect(ref)}")
    end
  end
end
