defmodule ADK.Workflow.Graph.RuntimeTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow.Graph
  alias ADK.Workflow.Graph.{Runtime, Mutation}

  defp simple_graph do
    Graph.build([{:START, :a}, {:a, :END}], %{a: :agent_a})
  end

  describe "lifecycle" do
    test "start and get" do
      {:ok, pid} = Runtime.start_link(simple_graph())
      g = Runtime.get(pid)
      assert %Graph{} = g
      assert Map.has_key?(g.nodes, :a)
    end
  end

  describe "mutate/2" do
    test "applies a successful mutation" do
      {:ok, pid} = Runtime.start_link(simple_graph())

      assert :ok =
               Runtime.mutate(pid, fn g ->
                 Mutation.add_node(g, :b, :agent_b)
               end)

      g = Runtime.get(pid)
      assert Map.has_key?(g.nodes, :b)
    end

    test "rejects a failed mutation (state unchanged)" do
      {:ok, pid} = Runtime.start_link(simple_graph())

      assert {:error, _} =
               Runtime.mutate(pid, fn g ->
                 Mutation.add_node(g, :a, :dup)
               end)

      g = Runtime.get(pid)
      assert g.nodes[:a] == :agent_a
    end
  end

  describe "history/1" do
    test "tracks history after mutations" do
      {:ok, pid} = Runtime.start_link(simple_graph())
      assert Runtime.history(pid) == []

      Runtime.mutate(pid, fn g -> Mutation.add_node(g, :b, :b) end)
      assert length(Runtime.history(pid)) == 1

      Runtime.mutate(pid, fn g -> Mutation.add_node(g, :c, :c) end)
      assert length(Runtime.history(pid)) == 2
    end

    test "limits history to 10 states" do
      {:ok, pid} = Runtime.start_link(simple_graph())

      for i <- 1..15 do
        node_id = String.to_atom("node_#{i}")
        Runtime.mutate(pid, fn g -> Mutation.add_node(g, node_id, node_id) end)
      end

      assert length(Runtime.history(pid)) == 10
    end
  end

  describe "rollback/1" do
    test "reverts to previous state" do
      {:ok, pid} = Runtime.start_link(simple_graph())
      Runtime.mutate(pid, fn g -> Mutation.add_node(g, :b, :agent_b) end)

      assert Map.has_key?(Runtime.get(pid).nodes, :b)
      assert :ok = Runtime.rollback(pid)
      refute Map.has_key?(Runtime.get(pid).nodes, :b)
    end

    test "returns error when no history" do
      {:ok, pid} = Runtime.start_link(simple_graph())
      assert {:error, :no_history} = Runtime.rollback(pid)
    end

    test "multiple rollbacks" do
      {:ok, pid} = Runtime.start_link(simple_graph())
      Runtime.mutate(pid, fn g -> Mutation.add_node(g, :b, :b) end)
      Runtime.mutate(pid, fn g -> Mutation.add_node(g, :c, :c) end)

      Runtime.rollback(pid)
      assert Map.has_key?(Runtime.get(pid).nodes, :b)
      refute Map.has_key?(Runtime.get(pid).nodes, :c)

      Runtime.rollback(pid)
      refute Map.has_key?(Runtime.get(pid).nodes, :b)
    end
  end
end
