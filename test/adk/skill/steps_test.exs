defmodule ADK.Skill.StepsTest do
  use ExUnit.Case, async: true

  alias ADK.Skill.Steps

  describe "compile_plan/1" do
    test "compiles steps into plan with correct structure" do
      steps = [
        %Steps{name: :a, handler: fn _ -> :ok end, depends_on: []},
        %Steps{name: :b, handler: fn _ -> :ok end, depends_on: [:a]}
      ]

      plan = Steps.compile_plan(steps)
      assert is_map(plan)
      assert length(plan["steps"]) == 2

      [step_a, step_b] = plan["steps"]
      assert step_a["id"] == "a"
      refute Map.has_key?(step_a, "depends_on")
      assert step_b["id"] == "b"
      assert step_b["depends_on"] == ["a"]
    end

    test "includes requires_approval when set" do
      steps = [
        %Steps{
          name: :deploy,
          handler: fn _ -> :ok end,
          depends_on: [],
          opts: [requires_approval: true]
        }
      ]

      plan = Steps.compile_plan(steps)
      [step] = plan["steps"]
      assert step["requires_approval"] == true
    end

    test "empty steps produce empty plan" do
      plan = Steps.compile_plan([])
      assert plan["steps"] == []
    end
  end

  describe "validate/1" do
    test "returns :ok for valid steps" do
      steps = [
        %Steps{name: :a, handler: fn _ -> :ok end, depends_on: []},
        %Steps{name: :b, handler: fn _ -> :ok end, depends_on: [:a]}
      ]

      assert Steps.validate(steps) == :ok
    end

    test "detects undefined dependencies" do
      steps = [
        %Steps{name: :a, handler: fn _ -> :ok end, depends_on: [:nonexistent]}
      ]

      assert {:error, msg} = Steps.validate(steps)
      assert msg =~ "undefined step"
      assert msg =~ ":nonexistent"
    end

    test "detects duplicate names" do
      steps = [
        %Steps{name: :a, handler: fn _ -> :ok end, depends_on: []},
        %Steps{name: :a, handler: fn _ -> :ok end, depends_on: []}
      ]

      assert {:error, msg} = Steps.validate(steps)
      assert msg =~ "Duplicate"
    end

    test "detects cycles" do
      steps = [
        %Steps{name: :a, handler: fn _ -> :ok end, depends_on: [:b]},
        %Steps{name: :b, handler: fn _ -> :ok end, depends_on: [:a]}
      ]

      assert {:error, msg} = Steps.validate(steps)
      assert msg =~ "Cycle"
    end

    test "detects self-referencing cycle" do
      steps = [
        %Steps{name: :a, handler: fn _ -> :ok end, depends_on: [:a]}
      ]

      assert {:error, msg} = Steps.validate(steps)
      assert msg =~ "Cycle"
    end
  end
end
