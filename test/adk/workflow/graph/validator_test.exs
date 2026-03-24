defmodule ADK.Workflow.Graph.ValidatorTest do
  use ExUnit.Case, async: true

  alias ADK.Workflow.Graph
  alias ADK.Workflow.Graph.Validator

  describe "validate/1" do
    test "valid simple graph" do
      g = Graph.build([{:START, :a}, {:a, :END}], %{a: :agent_a})
      assert :ok = Validator.validate(g)
    end

    test "missing START" do
      g = %Graph{nodes: %{a: :a, END: :END}, edges: [{:a, :END}]}
      assert {:error, reasons} = Validator.validate(g)
      assert Enum.any?(reasons, &String.contains?(&1, "START"))
    end

    test "END not reachable" do
      g = %Graph{nodes: %{START: :START, a: :a, END: :END}, edges: [{:START, :a}]}
      assert {:error, reasons} = Validator.validate(g)
      assert Enum.any?(reasons, &String.contains?(&1, "END"))
    end

    test "orphan nodes detected" do
      g = %Graph{
        nodes: %{START: :START, a: :a, b: :b, orphan: :orphan, END: :END},
        edges: [{:START, :a}, {:a, :b}, {:b, :END}]
      }
      assert {:error, reasons} = Validator.validate(g)
      assert Enum.any?(reasons, &String.contains?(&1, "orphan"))
    end

    test "cycle detected" do
      g = %Graph{
        nodes: %{START: :START, a: :a, b: :b, END: :END},
        edges: [{:START, :a}, {:a, :b}, {:b, :a}, {:b, :END}]
      }
      assert {:error, reasons} = Validator.validate(g)
      assert Enum.any?(reasons, &String.contains?(&1, "cycle"))
    end
  end

  describe "acyclic?/1" do
    test "returns true for DAG" do
      g = Graph.build([{:START, :a}, {:a, :END}], %{a: :a})
      assert Validator.acyclic?(g)
    end

    test "returns false for cyclic graph" do
      g = %Graph{
        nodes: %{START: :START, a: :a, b: :b, END: :END},
        edges: [{:START, :a}, {:a, :b}, {:b, :a}, {:a, :END}]
      }
      refute Validator.acyclic?(g)
    end
  end
end
