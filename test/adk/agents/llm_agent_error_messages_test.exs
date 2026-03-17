# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Agents.LlmAgentErrorMessagesTest do
  @moduledoc """
  Parity tests for Python's tests/unittests/agents/test_llm_agent_error_messages.py

  Verifies enhanced error messages in agent handling when a requested agent
  is not found, including listing all available agents and helpful diagnostics.
  """
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent

  describe "get_agent_to_run/2 - enhanced error messages" do
    test "raises error with enhanced message when agent not found" do
      root_agent =
        LlmAgent.new(
          name: "root",
          model: "gemini-2.0-flash",
          sub_agents: [
            LlmAgent.new(name: "agent_a", model: "gemini-2.0-flash"),
            LlmAgent.new(name: "agent_b", model: "gemini-2.0-flash")
          ]
        )

      assert_raise ArgumentError, fn ->
        LlmAgent.get_agent_to_run(root_agent, "nonexistent_agent")
      end
    end

    test "error message contains missing agent name" do
      root_agent =
        LlmAgent.new(
          name: "root",
          model: "gemini-2.0-flash",
          sub_agents: [
            LlmAgent.new(name: "agent_a", model: "gemini-2.0-flash"),
            LlmAgent.new(name: "agent_b", model: "gemini-2.0-flash")
          ]
        )

      error =
        assert_raise ArgumentError, fn ->
          LlmAgent.get_agent_to_run(root_agent, "nonexistent_agent")
        end

      assert error.message =~ "nonexistent_agent"
    end

    test "error message lists all available agents" do
      root_agent =
        LlmAgent.new(
          name: "root",
          model: "gemini-2.0-flash",
          sub_agents: [
            LlmAgent.new(name: "agent_a", model: "gemini-2.0-flash"),
            LlmAgent.new(name: "agent_b", model: "gemini-2.0-flash")
          ]
        )

      error =
        assert_raise ArgumentError, fn ->
          LlmAgent.get_agent_to_run(root_agent, "nonexistent_agent")
        end

      assert error.message =~ "Available agents:"
      assert error.message =~ "agent_a"
      assert error.message =~ "agent_b"
    end

    test "error message includes possible causes and suggested fixes" do
      root_agent =
        LlmAgent.new(
          name: "root",
          model: "gemini-2.0-flash",
          sub_agents: [
            LlmAgent.new(name: "agent_a", model: "gemini-2.0-flash")
          ]
        )

      error =
        assert_raise ArgumentError, fn ->
          LlmAgent.get_agent_to_run(root_agent, "nonexistent_agent")
        end

      assert error.message =~ "Possible causes:"
      assert error.message =~ "Suggested fixes:"
    end
  end

  describe "get_available_agent_names/1 - agent tree traversal" do
    test "collects all agent names from a nested tree" do
      root_agent =
        LlmAgent.new(
          name: "orchestrator",
          model: "gemini-2.0-flash",
          sub_agents: [
            LlmAgent.new(
              name: "parent_agent",
              model: "gemini-2.0-flash",
              sub_agents: [
                LlmAgent.new(name: "child_agent", model: "gemini-2.0-flash")
              ]
            )
          ]
        )

      available_agents = LlmAgent.get_available_agent_names(root_agent)

      assert "orchestrator" in available_agents
      assert "parent_agent" in available_agents
      assert "child_agent" in available_agents
      assert length(available_agents) == 3
    end

    test "includes only the root agent when no sub_agents" do
      root_agent = LlmAgent.new(name: "solo", model: "gemini-2.0-flash")
      available_agents = LlmAgent.get_available_agent_names(root_agent)

      assert available_agents == ["solo"]
    end
  end

  describe "get_agent_to_run/2 - shows all agents without truncation" do
    test "error message shows all agents even with 100 sub-agents" do
      sub_agents =
        Enum.map(0..99, fn i ->
          LlmAgent.new(name: "agent_#{i}", model: "gemini-2.0-flash")
        end)

      root_agent =
        LlmAgent.new(
          name: "root",
          model: "gemini-2.0-flash",
          sub_agents: sub_agents
        )

      error =
        assert_raise ArgumentError, fn ->
          LlmAgent.get_agent_to_run(root_agent, "nonexistent")
        end

      # All agents should appear - no truncation
      assert error.message =~ "agent_0"
      assert error.message =~ "agent_99"
      refute error.message =~ "showing first 20 of"
    end
  end

  describe "get_agent_to_run/2 - successful lookup" do
    test "returns ok tuple when agent is found directly" do
      target = LlmAgent.new(name: "target_agent", model: "gemini-2.0-flash")

      root_agent =
        LlmAgent.new(
          name: "root",
          model: "gemini-2.0-flash",
          sub_agents: [target]
        )

      assert {:ok, found} = LlmAgent.get_agent_to_run(root_agent, "target_agent")
      assert found.name == "target_agent"
    end

    test "returns ok tuple when agent found nested deeply" do
      deep =
        LlmAgent.new(
          name: "root",
          model: "gemini-2.0-flash",
          sub_agents: [
            LlmAgent.new(
              name: "level1",
              model: "gemini-2.0-flash",
              sub_agents: [
                LlmAgent.new(
                  name: "level2",
                  model: "gemini-2.0-flash",
                  sub_agents: [
                    LlmAgent.new(name: "deep_agent", model: "gemini-2.0-flash")
                  ]
                )
              ]
            )
          ]
        )

      assert {:ok, found} = LlmAgent.get_agent_to_run(deep, "deep_agent")
      assert found.name == "deep_agent"
    end

    test "returns ok for root agent itself" do
      root_agent = LlmAgent.new(name: "root", model: "gemini-2.0-flash")
      assert {:ok, found} = LlmAgent.get_agent_to_run(root_agent, "root")
      assert found.name == "root"
    end
  end
end
