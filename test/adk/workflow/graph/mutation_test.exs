defmodule ADK.Workflow.Graph.MutationTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow.Graph
  alias ADK.Workflow.Graph.Mutation

  defp simple_graph do
    Graph.build(
      [{:START, :a}, {:a, :b}, {:b, :END}],
      %{a: :agent_a, b: :agent_b}
    )
  end

  describe "add_node/3" do
    test "adds a new node" do
      g = simple_graph()
      assert {:ok, g2} = Mutation.add_node(g, :c, :agent_c)
      assert Map.has_key?(g2.nodes, :c)
      assert g2.nodes[:c] == :agent_c
    end

    test "rejects duplicate node" do
      g = simple_graph()
      assert {:error, _} = Mutation.add_node(g, :a, :other)
    end
  end

  describe "remove_node/2" do
    test "removes node and its edges" do
      g = simple_graph()
      assert {:ok, g2} = Mutation.remove_node(g, :b)
      refute Map.has_key?(g2.nodes, :b)
      refute Enum.any?(g2.edges, fn {from, to} -> from == :b or to == :b end)
    end

    test "rejects unknown node" do
      g = simple_graph()
      assert {:error, _} = Mutation.remove_node(g, :nonexistent)
    end
  end

  describe "add_edge/2" do
    test "adds a valid edge" do
      g = simple_graph()
      {:ok, g2} = Mutation.add_node(g, :c, :agent_c)
      assert {:ok, g3} = Mutation.add_edge(g2, {:b, :c})
      assert {:b, :c} in g3.edges
    end

    test "rejects edge creating a cycle" do
      g = simple_graph()
      assert {:error, _msg} = Mutation.add_edge(g, {:b, :a})
    end

    test "rejects edge with dangling reference" do
      g = simple_graph()
      assert {:error, _} = Mutation.add_edge(g, {:a, :nonexistent})
    end
  end

  describe "remove_edge/3" do
    test "removes an existing edge" do
      g = simple_graph()
      assert {:ok, g2} = Mutation.remove_edge(g, :a, :b)
      refute {:a, :b} in g2.edges
    end

    test "rejects removing nonexistent edge" do
      g = simple_graph()
      assert {:error, _} = Mutation.remove_edge(g, :a, :END)
    end
  end

  describe "replace_node/3" do
    test "replaces node definition" do
      g = simple_graph()
      assert {:ok, g2} = Mutation.replace_node(g, :a, :new_agent)
      assert g2.nodes[:a] == :new_agent
      # edges unchanged
      assert g2.edges == g.edges
    end

    test "rejects unknown node" do
      g = simple_graph()
      assert {:error, _} = Mutation.replace_node(g, :nonexistent, :x)
    end
  end

  describe "merge/2" do
    test "merges two graphs" do
      g1 = Graph.build([{:START, :a}, {:a, :END}], %{a: :agent_a})
      g2 = Graph.build([{:START, :b}, {:b, :END}], %{b: :agent_b})
      assert {:ok, merged} = Mutation.merge(g1, g2)
      assert Map.has_key?(merged.nodes, :a)
      assert Map.has_key?(merged.nodes, :b)
    end

    test "rejects merge that creates cycle" do
      g1 = Graph.build([{:START, :a}, {:a, :b}, {:b, :END}], %{a: :a, b: :b})
      g2 = Graph.build([{:START, :b}, {:b, :a}, {:a, :END}], %{a: :a, b: :b})
      # g1 has a->b, g2 has b->a => cycle
      assert {:error, _} = Mutation.merge(g1, g2)
    end
  end
end
