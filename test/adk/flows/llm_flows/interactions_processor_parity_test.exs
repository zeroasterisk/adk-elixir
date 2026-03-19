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

defmodule ADK.Flows.LlmFlows.InteractionsProcessorParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_interactions_processor.py`.

  The Python `InteractionsRequestProcessor` manages stateful conversation
  chaining via the Interactions API. It provides two key behaviors:

  1. **`_find_previous_interaction_id`** — reverse-searches session events
     to find the most recent model event from a specific agent, filtered
     by branch, returning its `interaction_id` for conversation chaining.

  2. **`_is_event_in_branch`** — checks whether an event belongs to the
     current branch context (root events visible everywhere; branched
     events visible only within their branch).

  The Elixir ADK does not yet have an `interaction_id` field or a dedicated
  `InteractionsProcessor` module. These tests port the behavioral patterns:

  - Finding the last agent event from a set of session events
  - Branch-aware event filtering using the Python `_is_event_in_branch`
    semantics (which differ from `Event.on_branch?/2`)
  - Combined agent-name + branch filtering for conversation history lookup

  These patterns are foundational for future Interactions API support and
  validate the filtering primitives that would underpin such a feature.
  """

  use ExUnit.Case, async: true

  alias ADK.Event

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Python-parity branch check: mirrors `_is_event_in_branch(current_branch, event)`.
  #
  # Rules:
  # - If current_branch is nil → include only events without a branch
  # - If event has no branch → include (root-level events visible everywhere)
  # - If event.branch == current_branch → include
  # - Otherwise → exclude
  defp is_event_in_branch(nil, event), do: event.branch == nil
  defp is_event_in_branch(_current_branch, %{branch: nil}), do: true
  defp is_event_in_branch(current_branch, event), do: event.branch == current_branch

  # Find the most recent event from a specific agent, filtered by branch.
  # Mirrors Python's `_find_previous_interaction_id` traversal pattern.
  # Returns the matching event (or nil), rather than an interaction_id,
  # since Elixir ADK doesn't have that field yet.
  defp find_last_agent_event(events, agent_name, current_branch) do
    events
    |> Enum.reverse()
    |> Enum.find(fn event ->
      is_event_in_branch(current_branch, event) && event.author == agent_name
    end)
  end

  # ── _find_previous_interaction_id parity ───────────────────────────────

  describe "find_last_agent_event (mirrors _find_previous_interaction_id)" do
    test "returns nil when there are no events" do
      assert find_last_agent_event([], "test_agent", nil) == nil
    end

    test "returns nil when only user events exist" do
      events = [
        Event.new(%{invocation_id: "inv1", author: "user", content: %{parts: [%{text: "Hello"}]}}),
        Event.new(%{invocation_id: "inv2", author: "user", content: %{parts: [%{text: "World"}]}})
      ]

      assert find_last_agent_event(events, "test_agent", nil) == nil
    end

    test "finds model event from the correct agent" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "user",
          content: %{parts: [%{text: "Hello"}]}
        }),
        Event.new(%{
          invocation_id: "inv2",
          author: "test_agent",
          content: %{parts: [%{text: "Response"}]}
        })
      ]

      result = find_last_agent_event(events, "test_agent", nil)
      assert result != nil
      assert result.author == "test_agent"
      assert result.invocation_id == "inv2"
    end

    test "returns the most recent agent event" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "user",
          content: %{parts: [%{text: "Hello"}]}
        }),
        Event.new(%{
          invocation_id: "inv2",
          author: "test_agent",
          content: %{parts: [%{text: "First response"}]}
        }),
        Event.new(%{
          invocation_id: "inv3",
          author: "user",
          content: %{parts: [%{text: "Second message"}]}
        }),
        Event.new(%{
          invocation_id: "inv4",
          author: "test_agent",
          content: %{parts: [%{text: "Second response"}]}
        })
      ]

      result = find_last_agent_event(events, "test_agent", nil)
      assert result.invocation_id == "inv4"
      assert result.content.parts |> hd() |> Map.get(:text) == "Second response"
    end

    test "skips user events even when searching for agent events" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "test_agent",
          content: %{parts: [%{text: "Model response"}]}
        }),
        Event.new(%{
          invocation_id: "inv2",
          author: "user",
          content: %{parts: [%{text: "User message"}]}
        })
      ]

      result = find_last_agent_event(events, "test_agent", nil)
      assert result.invocation_id == "inv1"
      assert result.author == "test_agent"
    end

    test "only finds events from the specified agent, not other agents" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "other_agent",
          content: %{parts: [%{text: "I am other agent"}]}
        }),
        Event.new(%{
          invocation_id: "inv2",
          author: "user",
          content: %{parts: [%{text: "Hi"}]}
        })
      ]

      assert find_last_agent_event(events, "test_agent", nil) == nil
    end

    test "filters by branch when branch is specified" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "test_agent",
          content: %{parts: [%{text: "On different branch"}]},
          branch: "other_branch"
        }),
        Event.new(%{
          invocation_id: "inv2",
          author: "test_agent",
          content: %{parts: [%{text: "On correct branch"}]},
          branch: "my_branch"
        })
      ]

      result = find_last_agent_event(events, "test_agent", "my_branch")
      assert result.invocation_id == "inv2"
      assert result.content.parts |> hd() |> Map.get(:text) == "On correct branch"
    end

    test "root events (no branch) are visible from any branch" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "test_agent",
          content: %{parts: [%{text: "Root-level response"}]},
          branch: nil
        })
      ]

      result = find_last_agent_event(events, "test_agent", "some.deep.branch")
      assert result != nil
      assert result.invocation_id == "inv1"
    end

    test "branched events are NOT visible from root (nil branch)" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "test_agent",
          content: %{parts: [%{text: "Branched response"}]},
          branch: "some_branch"
        })
      ]

      # When current_branch is nil (root), branched events should be excluded
      assert find_last_agent_event(events, "test_agent", nil) == nil
    end
  end

  # ── _is_event_in_branch parity ─────────────────────────────────────────

  describe "is_event_in_branch (mirrors Python _is_event_in_branch)" do
    test "no current branch — root events included" do
      event = Event.new(%{
        invocation_id: "inv1",
        author: "test",
        content: %{parts: [%{text: "test"}]}
      })

      assert is_event_in_branch(nil, event) == true
    end

    test "no current branch — branched events excluded" do
      event = Event.new(%{
        invocation_id: "inv2",
        author: "test",
        content: %{parts: [%{text: "test"}]},
        branch: "some_branch"
      })

      assert is_event_in_branch(nil, event) == false
    end

    test "same branch — events included" do
      event = Event.new(%{
        invocation_id: "inv1",
        author: "test",
        content: %{parts: [%{text: "test"}]},
        branch: "root.child"
      })

      assert is_event_in_branch("root.child", event) == true
    end

    test "different branch — events excluded" do
      event = Event.new(%{
        invocation_id: "inv1",
        author: "test",
        content: %{parts: [%{text: "test"}]},
        branch: "root.other"
      })

      assert is_event_in_branch("root.child", event) == false
    end

    test "root events included in child branches" do
      event = Event.new(%{
        invocation_id: "inv1",
        author: "test",
        content: %{parts: [%{text: "test"}]},
        branch: nil
      })

      assert is_event_in_branch("root.child", event) == true
    end

    test "child branch events NOT visible from parent branch" do
      event = Event.new(%{
        invocation_id: "inv1",
        author: "test",
        content: %{parts: [%{text: "test"}]},
        branch: "root.child.grandchild"
      })

      assert is_event_in_branch("root.child", event) == false
    end
  end

  # ── Combined agent + branch filtering ──────────────────────────────────

  describe "combined agent and branch filtering" do
    test "multi-agent conversation — each agent finds only its own events" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "user",
          content: %{parts: [%{text: "Hello"}]}
        }),
        Event.new(%{
          invocation_id: "inv2",
          author: "agent_a",
          content: %{parts: [%{text: "Agent A says hi"}]}
        }),
        Event.new(%{
          invocation_id: "inv3",
          author: "agent_b",
          content: %{parts: [%{text: "Agent B says hi"}]}
        }),
        Event.new(%{
          invocation_id: "inv4",
          author: "agent_a",
          content: %{parts: [%{text: "Agent A second reply"}]}
        })
      ]

      result_a = find_last_agent_event(events, "agent_a", nil)
      assert result_a.invocation_id == "inv4"

      result_b = find_last_agent_event(events, "agent_b", nil)
      assert result_b.invocation_id == "inv3"

      # Non-existent agent finds nothing
      assert find_last_agent_event(events, "agent_c", nil) == nil
    end

    test "branched multi-agent — agent on wrong branch is invisible" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "router",
          content: %{parts: [%{text: "Routing..."}]},
          branch: nil
        }),
        Event.new(%{
          invocation_id: "inv2",
          author: "weather_agent",
          content: %{parts: [%{text: "Weather data"}]},
          branch: "router.weather_agent"
        }),
        Event.new(%{
          invocation_id: "inv3",
          author: "news_agent",
          content: %{parts: [%{text: "News data"}]},
          branch: "router.news_agent"
        })
      ]

      # Weather agent on weather branch finds itself
      result =
        find_last_agent_event(events, "weather_agent", "router.weather_agent")

      assert result.invocation_id == "inv2"

      # Weather agent on news branch — not visible (different branch)
      assert find_last_agent_event(
               events,
               "weather_agent",
               "router.news_agent"
             ) == nil

      # Router (root event) is visible from any branch
      result = find_last_agent_event(events, "router", "router.weather_agent")
      assert result.invocation_id == "inv1"
    end

    test "conversation with interleaved user and agent events across branches" do
      events = [
        Event.new(%{
          invocation_id: "inv1",
          author: "user",
          content: %{parts: [%{text: "Start"}]}
        }),
        Event.new(%{
          invocation_id: "inv2",
          author: "orchestrator",
          content: %{parts: [%{text: "Delegating..."}]}
        }),
        Event.new(%{
          invocation_id: "inv3",
          author: "worker_a",
          content: %{parts: [%{text: "Work A done"}]},
          branch: "orchestrator.worker_a"
        }),
        Event.new(%{
          invocation_id: "inv4",
          author: "worker_b",
          content: %{parts: [%{text: "Work B done"}]},
          branch: "orchestrator.worker_b"
        }),
        Event.new(%{
          invocation_id: "inv5",
          author: "user",
          content: %{parts: [%{text: "Follow up"}]}
        }),
        Event.new(%{
          invocation_id: "inv6",
          author: "orchestrator",
          content: %{parts: [%{text: "Final answer"}]}
        })
      ]

      # From root, orchestrator's latest is inv6
      result = find_last_agent_event(events, "orchestrator", nil)
      assert result.invocation_id == "inv6"

      # Worker A is only visible from its own branch
      result =
        find_last_agent_event(events, "worker_a", "orchestrator.worker_a")

      assert result.invocation_id == "inv3"

      # Worker A not visible from root (branched event from nil branch perspective)
      assert find_last_agent_event(events, "worker_a", nil) == nil

      # Worker B not visible from Worker A's branch
      assert find_last_agent_event(
               events,
               "worker_b",
               "orchestrator.worker_a"
             ) == nil
    end
  end
end
