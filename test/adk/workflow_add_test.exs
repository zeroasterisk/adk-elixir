defmodule ADK.WorkflowAddTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow

  defp make_agent(name) do
    ADK.Agent.Custom.new(
      name: name,
      run_fn: fn _agent, _ctx ->
        [ADK.Event.new(author: name, content: %{"parts" => [%{"text" => "output from #{name}"}]})]
      end
    )
  end

  describe "add/3" do
    test "adds a single edge and node" do
      w = Workflow.new(name: "test")
      agent = make_agent("a")

      w = Workflow.add(w, {:START, :a, :END}, %{a: agent})

      assert length(w.edges) == 1
      assert Map.has_key?(w.nodes, :a)
      # Expanded from {:START, :a, :END}
      assert length(w.graph.edges) == 2
      assert Map.has_key?(w.graph.nodes, :a)
    end

    test "adds multiple edges and nodes incrementally" do
      w = Workflow.new(name: "incremental")

      # First step
      w = Workflow.add(w, {:START, :step1}, %{step1: make_agent("step1")})
      assert length(w.graph.edges) == 1

      # Second step
      w = Workflow.add(w, {:step1, :step2}, %{step2: make_agent("step2")})
      assert length(w.graph.edges) == 2

      # End
      w = Workflow.add(w, {:step2, :END})
      assert length(w.graph.edges) == 3

      assert :ok = Workflow.validate(w)
    end

    test "supports adding chains" do
      w = Workflow.new(name: "chain_add")

      w =
        Workflow.add(w, {:START, :a, :b, :c, :END}, %{
          a: make_agent("a"),
          b: make_agent("b"),
          c: make_agent("c")
        })

      assert length(w.graph.edges) == 4
      assert :ok = Workflow.validate(w)
    end

    test "merges nodes correctly" do
      w = Workflow.new(name: "merge", nodes: %{initial: make_agent("initial")})
      w = Workflow.add(w, {:START, :new}, %{new: make_agent("new")})

      assert Map.has_key?(w.nodes, :initial)
      assert Map.has_key?(w.nodes, :new)
    end
  end
end
