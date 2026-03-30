defmodule ADK.WorkflowTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow
  alias ADK.Workflow.Graph

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
    %ADK.Context{invocation_id: "test-inv"}
  end

  describe "new/1" do
    test "creates a workflow with name" do
      w = Workflow.new(name: "test")
      assert w.name == "test"
      assert w.collaboration == :pipeline
    end

    test "creates workflow with edges and nodes" do
      agent = make_agent("step1")

      w =
        Workflow.new(
          name: "pipe",
          edges: [{:START, :step1, :END}],
          nodes: %{step1: agent}
        )

      assert w.graph != nil
      assert Map.has_key?(w.graph.nodes, :step1)
    end

    test "expands chain tuples into pairwise edges" do
      w = Workflow.new(name: "chain", edges: [{:START, :a, :b, :c, :END}])
      # Should have 4 pairwise edges
      assert length(w.graph.edges) == 4
    end

    test "preserves conditional edges" do
      w =
        Workflow.new(
          name: "cond",
          edges: [
            {:START, :router},
            {:router, %{"a" => :handler_a, "b" => :handler_b}}
          ]
        )

      assert {:conditional, %{"a" => :handler_a, "b" => :handler_b}} =
               Graph.outgoing(w.graph, :router)
    end
  end

  describe "build/1" do
    test "returns {:ok, workflow} for valid graph" do
      assert {:ok, w} =
               Workflow.build(
                 name: "valid",
                 edges: [{:START, :a, :END}],
                 nodes: %{a: make_agent("a")}
               )

      assert w.name == "valid"
    end

    test "returns {:error, reason} for missing START" do
      assert {:error, msg} =
               Workflow.build(
                 name: "bad",
                 edges: [{:a, :b}],
                 nodes: %{a: make_agent("a"), b: make_agent("b")}
               )

      assert msg =~ "START"
    end

    test "returns {:error, reason} for unreachable nodes" do
      assert {:error, msg} =
               Workflow.build(
                 name: "unreach",
                 edges: [{:START, :a, :END}, {:b, :c}],
                 nodes: %{a: make_agent("a"), b: make_agent("b"), c: make_agent("c")}
               )

      assert msg =~ "unreachable"
    end

    test "returns {:error, reason} for nodes in node_defs not in edges" do
      assert {:error, msg} =
               Workflow.build(
                 name: "unreach_def",
                 edges: [{:START, :a, :END}],
                 nodes: %{a: make_agent("a"), b: make_agent("b")}
               )

      assert msg =~ "unreachable"
    end

    test "returns {:error, reason} for missing name" do
      assert {:error, _msg} = Workflow.build(edges: [{:START, :a, :END}])
    end
  end

  describe "validate/1" do
    test "valid linear graph" do
      w = Workflow.new(name: "v", edges: [{:START, :a, :b, :END}])
      assert :ok = Workflow.validate(w)
    end

    test "detects cycles" do
      w = Workflow.new(name: "cycle", edges: [{:START, :a}, {:a, :b}, {:b, :a}])
      assert {:error, msg} = Workflow.validate(w)
      assert msg =~ "cycle"
    end
  end

  describe "run/2 — simple sequential" do
    test "executes START → agent → END" do
      agent = make_agent("worker", "hello world")

      w =
        Workflow.new(
          name: "simple",
          edges: [{:START, :worker, :END}],
          nodes: %{worker: agent}
        )

      events = Workflow.run(w, make_ctx())
      assert length(events) > 0
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "hello world" in texts
    end

    test "executes multi-step pipeline" do
      a = make_agent("step_a", "from A")
      b = make_agent("step_b", "from B")
      c = make_agent("step_c", "from C")

      w =
        Workflow.new(
          name: "pipeline",
          edges: [{:START, :a, :b, :c, :END}],
          nodes: %{a: a, b: b, c: c}
        )

      events = Workflow.run(w, make_ctx())
      authors = Enum.map(events, & &1.author) |> Enum.reject(&is_nil/1)
      assert "step_a" in authors
      assert "step_b" in authors
      assert "step_c" in authors
    end
  end

  describe "run/2 — function nodes" do
    test "executes anonymous function as node" do
      node_fn = fn _ctx ->
        [ADK.Event.new(author: "fn_node", content: %{"parts" => [%{"text" => "fn output"}]})]
      end

      w =
        Workflow.new(
          name: "fn_workflow",
          edges: [{:START, :processor, :END}],
          nodes: %{processor: node_fn}
        )

      events = Workflow.run(w, make_ctx())
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "fn output" in texts
    end
  end

  describe "run/2 — conditional routing" do
    test "routes based on event metadata" do
      router_fn = fn _ctx ->
        [
          ADK.Event.new(
            author: "router",
            content: %{"parts" => [%{"text" => "routing..."}]},
            custom_metadata: %{"route" => "path_b"}
          )
        ]
      end

      handler_a = make_agent("handler_a", "took path A")
      handler_b = make_agent("handler_b", "took path B")

      w =
        Workflow.new(
          name: "routing",
          edges: [
            {:START, :router},
            {:router, %{"path_a" => :handler_a, "path_b" => :handler_b}},
            {:handler_a, :END},
            {:handler_b, :END}
          ],
          nodes: %{router: router_fn, handler_a: handler_a, handler_b: handler_b}
        )

      events = Workflow.run(w, make_ctx())
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "took path B" in texts
      refute "took path A" in texts
    end
  end

  describe "run/2 — parallel fan-out" do
    test "executes parallel branches" do
      a = make_agent("branch_a", "result A")
      b = make_agent("branch_b", "result B")

      w =
        Workflow.new(
          name: "parallel",
          edges: [
            {:START, :a},
            {:START, :b},
            {:a, :END},
            {:b, :END}
          ],
          nodes: %{a: a, b: b}
        )

      events = Workflow.run(w, make_ctx())
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "result A" in texts
      assert "result B" in texts
    end
  end

  describe "ADK.Agent protocol" do
    test "workflow implements ADK.Agent" do
      w = Workflow.new(name: "proto_test", edges: [{:START, :END}])
      assert ADK.Agent.name(w) == "proto_test"
      assert ADK.Agent.description(w) == "Graph-based workflow"
      assert is_list(ADK.Agent.sub_agents(w))
    end

    test "workflow can be run via protocol" do
      agent = make_agent("inner", "proto output")

      w =
        Workflow.new(
          name: "proto_run",
          edges: [{:START, :inner, :END}],
          nodes: %{inner: agent}
        )

      events = ADK.Agent.run(w, make_ctx())
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "proto output" in texts
    end

    test "workflow can be nested inside sequential agent" do
      inner = make_agent("inner_agent", "nested output")

      w =
        Workflow.new(
          name: "inner_workflow",
          edges: [{:START, :inner, :END}],
          nodes: %{inner: inner}
        )

      seq =
        ADK.Agent.SequentialAgent.new(
          name: "outer",
          sub_agents: [w]
        )

      events = ADK.Agent.run(seq, make_ctx())
      texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)
      assert "nested output" in texts
    end
  end
end
