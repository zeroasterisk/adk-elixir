defmodule ADK.Flows.NlPlanningTest do
  @moduledoc """
  Tests for NL planning flow behavior — ported from Python's
  tests/unittests/flows/llm_flows/test_nl_planning.py.

  Covers: BuiltIn planner content preservation, thinking config application,
  PlanReAct instruction appending, and thought-flag removal from contents.
  """
  use ExUnit.Case, async: true

  alias ADK.Planner.BuiltIn
  alias ADK.Planner.PlanReAct

  # ---------------------------------------------------------------------------
  # BuiltIn Planner — content list unchanged
  # ---------------------------------------------------------------------------

  describe "BuiltIn planner content preservation" do
    test "apply_thinking_config does not modify contents" do
      planner = %BuiltIn{thinking_config: %{thinking_budget: 1024}}

      contents = [
        %{role: :user, parts: [%{text: "Hello"}]},
        %{
          role: :model,
          parts: [
            %{text: "thinking...", thought: true},
            %{text: "Here is my response"}
          ]
        },
        %{role: :user, parts: [%{text: "Follow up"}]}
      ]

      request = %{model: "test-model", contents: contents}
      updated_request = BuiltIn.apply_thinking_config(planner, request)

      # Contents must be untouched — BuiltIn only touches generate_config
      assert updated_request.contents == contents
    end

    test "apply_thinking_config sets thinking_config on request" do
      planner = %BuiltIn{thinking_config: %{thinking_budget: 2048}}
      request = %{model: "test-model"}

      updated = BuiltIn.apply_thinking_config(planner, request)

      assert updated.generate_config.thinking_config.thinking_budget == 2048
    end

    test "build_planning_instruction returns nil (no-op)" do
      assert BuiltIn.build_planning_instruction(nil, %{}) == nil
    end

    test "process_planning_response returns nil (no-op)" do
      assert BuiltIn.process_planning_response(nil, [%{text: "hello"}]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # PlanReAct Planner — instruction appending
  # ---------------------------------------------------------------------------

  describe "PlanReAct planner instruction appending" do
    test "planning instruction is appended to existing system instruction" do
      planning_instruction = PlanReAct.build_planning_instruction(nil, %{})
      original = "Original instruction"

      # Simulate the request_processor behavior: append planning instruction
      merged = original <> "\n\n" <> planning_instruction

      assert String.starts_with?(merged, "Original instruction")
      assert String.contains?(merged, "/*PLANNING*/")
      assert String.contains?(merged, "/*REPLANNING*/")
      assert String.contains?(merged, "/*REASONING*/")
      assert String.contains?(merged, "/*ACTION*/")
      assert String.contains?(merged, "/*FINAL_ANSWER*/")
    end

    test "planning instruction is complete when no system instruction exists" do
      instruction = PlanReAct.build_planning_instruction(nil, %{})

      assert is_binary(instruction)
      assert String.length(instruction) > 100
      assert String.contains?(instruction, "/*PLANNING*/")
      assert String.contains?(instruction, "/*FINAL_ANSWER*/")
    end
  end

  # ---------------------------------------------------------------------------
  # PlanReAct Planner — thought removal from content parts
  # ---------------------------------------------------------------------------

  describe "PlanReAct planner thought-flag removal" do
    test "preserves parts without tags unchanged (thought flag intact)" do
      # Parts without planning tags pass through as-is — the planner
      # doesn't strip existing thought flags from non-tagged parts.
      # In the Python flow, thought removal is a separate step that happens
      # before building the request. Here we verify process_planning_response
      # handles non-tagged parts correctly (passes through).
      parts = [
        %{text: "initial query"},
        %{text: "Regular text"},
        %{text: "follow up"}
      ]

      processed = PlanReAct.process_planning_response(nil, parts)

      assert is_list(processed)
      assert length(processed) == 3

      # Non-tagged parts should NOT gain thought: true
      for part <- processed do
        assert Map.get(part, :thought) == nil,
               "Non-tagged part should not have thought=true: #{inspect(part)}"
      end
    end

    test "parts with planning tags get thought: true" do
      parts = [
        %{text: "/*REASONING*/ I think we need to analyze this."},
        %{text: "/*PLANNING*/ Step 1: search. Step 2: synthesize."},
        %{text: "/*ACTION*/ Running search tool."}
      ]

      processed = PlanReAct.process_planning_response(nil, parts)

      assert length(processed) == 3

      for part <- processed do
        assert part.thought == true,
               "Tagged part should have thought=true: #{inspect(part)}"
      end
    end

    test "FINAL_ANSWER splits thought from answer" do
      parts = [
        %{
          text: "/*REASONING*/ I analyzed the data. /*FINAL_ANSWER*/ The answer is 42."
        }
      ]

      processed = PlanReAct.process_planning_response(nil, parts)

      assert length(processed) == 2

      [thought_part, answer_part] = processed
      assert thought_part.thought == true
      assert String.contains?(thought_part.text, "/*REASONING*/")
      assert String.contains?(thought_part.text, "/*FINAL_ANSWER*/")

      assert Map.get(answer_part, :thought) == nil
      assert String.contains?(answer_part.text, "42")
    end

    test "content without any tags passes through unchanged" do
      parts = [
        %{text: "Hello, just chatting."},
        %{text: "No special tags here."}
      ]

      processed = PlanReAct.process_planning_response(nil, parts)

      assert length(processed) == 2

      for part <- processed do
        assert Map.get(part, :thought) == nil
      end
    end

    test "mixed content with thoughts, tags, and function calls" do
      parts = [
        %{text: "/*PLANNING*/ Need to search first."},
        %{function_call: %{name: "search", args: %{q: "test"}}},
        %{text: "Should not appear after FC"}
      ]

      processed = PlanReAct.process_planning_response(nil, parts)

      # Planning part becomes thought
      planning = Enum.at(processed, 0)
      assert planning.thought == true
      assert String.contains?(planning.text, "/*PLANNING*/")

      # Function call is preserved
      fc = Enum.at(processed, 1)
      assert Map.has_key?(fc, :function_call)

      # Text after function call group is dropped (Python behavior)
      assert length(processed) == 2
    end
  end
end
