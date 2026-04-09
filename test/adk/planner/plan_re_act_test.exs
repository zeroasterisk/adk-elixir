defmodule ADK.Planner.PlanReActTest do
  use ExUnit.Case, async: true

  alias ADK.Planner.PlanReAct

  test "build_planning_instruction returns string with formatting guidelines" do
    _planner = %PlanReAct{}
    instruction = PlanReAct.build_planning_instruction(nil, %{})

    assert is_binary(instruction)
    assert String.contains?(instruction, "/*PLANNING*/")
    assert String.contains?(instruction, "/*REPLANNING*/")
    assert String.contains?(instruction, "/*REASONING*/")
    assert String.contains?(instruction, "/*ACTION*/")
    assert String.contains?(instruction, "/*FINAL_ANSWER*/")
  end

  test "process_planning_response handles empty responses" do
    assert PlanReAct.process_planning_response(nil, []) == nil
    assert PlanReAct.process_planning_response(nil, nil) == nil
  end

  test "process_planning_response separates reasoning and final answer" do
    parts = [
      %{
        text:
          "Here is my reasoning: /*REASONING*/ This is why. /*FINAL_ANSWER*/ The answer is 42."
      }
    ]

    processed = PlanReAct.process_planning_response(nil, parts)

    assert length(processed) == 2

    assert Enum.at(processed, 0).text ==
             "Here is my reasoning: /*REASONING*/ This is why. /*FINAL_ANSWER*/"

    assert Enum.at(processed, 0).thought == true
    assert Enum.at(processed, 1).text == " The answer is 42."
    assert Map.get(Enum.at(processed, 1), :thought) == nil
  end

  test "process_planning_response handles reasoning tag alone" do
    parts = [
      %{text: "/*REASONING*/ I think we should do X."}
    ]

    processed = PlanReAct.process_planning_response(nil, parts)

    assert length(processed) == 1
    assert Enum.at(processed, 0).text == "/*REASONING*/ I think we should do X."
    assert Enum.at(processed, 0).thought == true
  end

  test "process_planning_response ignores text without tags" do
    parts = [
      %{text: "Hello, I am just chatting."}
    ]

    processed = PlanReAct.process_planning_response(nil, parts)

    assert length(processed) == 1
    assert Enum.at(processed, 0).text == "Hello, I am just chatting."
    assert Map.get(Enum.at(processed, 0), :thought) == nil
  end

  test "process_planning_response preserves function calls and subsequent parts" do
    parts = [
      %{text: "/*PLANNING*/ Need to search."},
      %{function_call: %{name: "search", args: %{q: "test"}}},
      %{text: "Random text"}
    ]

    processed = PlanReAct.process_planning_response(nil, parts)

    assert length(processed) == 2
    assert Enum.at(processed, 0).text == "/*PLANNING*/ Need to search."
    assert Enum.at(processed, 0).thought == true
    assert Map.has_key?(Enum.at(processed, 1), :function_call)
    # The subsequent text part is dropped if we follow Python logic strictly:
    # "Stop at the first (group of) function calls."
  end
end
