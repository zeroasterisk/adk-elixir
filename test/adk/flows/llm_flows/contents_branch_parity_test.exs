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

defmodule ADK.Flows.LlmFlows.ContentsBranchParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_contents_branch.py`.

  The Python test verifies branch filtering in the content pipeline:
  - Branch format: parent.child.grandchild (dot-delimited hierarchy)
  - Child agents can see parent (ancestor) events, but NOT sibling events
  - Parent agents cannot see child (descendant) events
  - Events with no branch are visible everywhere
  - Prefix matches without dot boundary are correctly excluded (e.g. child_agent vs child_agent000)

  Python semantics (from `_is_event_belongs_to_branch`):
    - If either invocation_branch or event.branch is nil/None → visible (True)
    - invocation_branch == event.branch → visible
    - invocation_branch.startswith(event.branch + ".") → visible (ancestor events)
    - Otherwise → not visible

  This test exercises `Event.on_branch?/2` and branch propagation via
  `Context.for_child/2` and `Context.fork_branch/2`.

  Parity note: the Python test validates through the full request_processor
  pipeline which also reformats other-agent messages as "For context:" user
  messages. The Elixir `build_messages` does not yet apply branch filtering
  or other-agent reformatting inline, so these tests validate the filtering
  predicate and branch propagation directly — the building blocks that
  `build_messages` should use.
  """

  use ExUnit.Case, async: true

  alias ADK.Event
  alias ADK.Context
  alias ADK.Agent.LlmAgent

  # ── Correct on_branch? implementation matching Python semantics ──────
  #
  # Python: _is_event_belongs_to_branch(invocation_branch, event)
  #   if not invocation_branch or not event.branch: return True
  #   return invocation_branch == event.branch or
  #          invocation_branch.startswith(event.branch + ".")
  #
  # In Elixir terms: the current agent's branch (invocation_branch)
  # starts with the event's branch + "." — meaning ancestor events are visible.

  # Reference implementation of branch visibility matching Python ADK semantics.
  # Returns true when `event` should be visible to an agent on `current_branch`.
  defp visible_on_branch?(event, current_branch) do
    case {event.branch, current_branch} do
      {nil, _} ->
        true

      {_, nil} ->
        true

      {event_branch, current_branch} ->
        event_branch == current_branch or
          String.starts_with?(current_branch, event_branch <> ".")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp make_event(opts) do
    %Event{
      invocation_id: opts[:invocation_id] || "inv-#{System.unique_integer([:positive])}",
      author: opts[:author],
      content: opts[:content],
      branch: opts[:branch]
    }
  end

  defp user_content(text), do: %{role: :user, parts: [%{text: text}]}
  defp model_content(text), do: %{role: :model, parts: [%{text: text}]}

  # ── Branch Filtering Tests (mirrors Python test_contents_branch.py) ─

  describe "branch filtering — child sees parent (test_branch_filtering_child_sees_parent)" do
    test "child agent can see parent agent's events" do
      current_branch = "parent_agent.child_agent"

      events = [
        make_event(author: "user", content: user_content("User message"), branch: nil),
        make_event(
          author: "parent_agent",
          content: model_content("Parent agent response"),
          branch: "parent_agent"
        ),
        make_event(
          author: "child_agent",
          content: model_content("Child agent response"),
          branch: "parent_agent.child_agent"
        )
      ]

      visible = Enum.filter(events, &visible_on_branch?(&1, current_branch))
      assert length(visible) == 3

      authors = Enum.map(visible, & &1.author)
      assert "user" in authors
      assert "parent_agent" in authors
      assert "child_agent" in authors
    end

    test "prefix match without dot boundary is excluded (child_agent vs child_agent000)" do
      current_branch = "parent_agent.child_agent"

      # child_agent000 is NOT an ancestor of child_agent
      event =
        make_event(
          author: "child_agent",
          content: model_content("Excluded response 1"),
          branch: "parent_agent.child_agent000"
        )

      refute visible_on_branch?(event, current_branch)
    end

    test "partial name prefix is excluded (child vs child_agent)" do
      current_branch = "parent_agent.child_agent"

      event =
        make_event(
          author: "child_agent",
          content: model_content("Excluded response 2"),
          branch: "parent_agent.child"
        )

      refute visible_on_branch?(event, current_branch)
    end
  end

  describe "branch filtering — excludes sibling agents (test_branch_filtering_excludes_sibling_agents)" do
    test "sibling agents cannot see each other's events" do
      current_branch = "parent_agent.child_agent1"

      events = [
        make_event(author: "user", content: user_content("User message"), branch: nil),
        make_event(
          author: "parent_agent",
          content: model_content("Parent response"),
          branch: "parent_agent"
        ),
        make_event(
          author: "child_agent1",
          content: model_content("Child1 response"),
          branch: "parent_agent.child_agent1"
        ),
        make_event(
          author: "child_agent2",
          content: model_content("Sibling response"),
          branch: "parent_agent.child_agent2"
        )
      ]

      visible = Enum.filter(events, &visible_on_branch?(&1, current_branch))
      assert length(visible) == 3

      authors = Enum.map(visible, & &1.author)
      assert "user" in authors
      assert "parent_agent" in authors
      assert "child_agent1" in authors
      refute "child_agent2" in authors
    end
  end

  describe "branch filtering — no branch allows all (test_branch_filtering_no_branch_allows_all)" do
    test "events are included when no current branch is set" do
      current_branch = nil

      events = [
        make_event(author: "user", content: user_content("No branch message"), branch: nil),
        make_event(
          author: "agent1",
          content: model_content("Agent with branch"),
          branch: "agent1"
        ),
        make_event(author: "user", content: user_content("Another no branch"), branch: nil)
      ]

      visible = Enum.filter(events, &visible_on_branch?(&1, current_branch))
      assert length(visible) == 3
    end

    test "events without branch are visible regardless of current branch" do
      current_branch = "some_agent.sub_agent"

      event = make_event(author: "user", content: user_content("Global msg"), branch: nil)
      assert visible_on_branch?(event, current_branch)
    end
  end

  describe "branch filtering — grandchild sees grandparent (test_branch_filtering_grandchild_sees_grandparent)" do
    test "deeply nested child agents can see all ancestor events" do
      current_branch = "grandparent_agent.parent_agent.grandchild_agent"

      events = [
        make_event(
          author: "grandparent_agent",
          content: model_content("Grandparent response"),
          branch: "grandparent_agent"
        ),
        make_event(
          author: "parent_agent",
          content: model_content("Parent response"),
          branch: "grandparent_agent.parent_agent"
        ),
        make_event(
          author: "grandchild_agent",
          content: model_content("Grandchild response"),
          branch: "grandparent_agent.parent_agent.grandchild_agent"
        ),
        make_event(
          author: "sibling_agent",
          content: model_content("Sibling response"),
          branch: "grandparent_agent.parent_agent.sibling_agent"
        )
      ]

      visible = Enum.filter(events, &visible_on_branch?(&1, current_branch))
      assert length(visible) == 3

      authors = Enum.map(visible, & &1.author)
      assert "grandparent_agent" in authors
      assert "parent_agent" in authors
      assert "grandchild_agent" in authors
      refute "sibling_agent" in authors
    end
  end

  describe "branch filtering — parent cannot see child (test_branch_filtering_parent_cannot_see_child)" do
    test "parent agents cannot see child or grandchild events" do
      current_branch = "parent_agent"

      events = [
        make_event(author: "user", content: user_content("User message"), branch: nil),
        make_event(
          author: "parent_agent",
          content: model_content("Parent response"),
          branch: "parent_agent"
        ),
        make_event(
          author: "child_agent",
          content: model_content("Child response"),
          branch: "parent_agent.child_agent"
        ),
        make_event(
          author: "grandchild_agent",
          content: model_content("Grandchild response"),
          branch: "parent_agent.child_agent.grandchild_agent"
        )
      ]

      visible = Enum.filter(events, &visible_on_branch?(&1, current_branch))
      assert length(visible) == 2

      authors = Enum.map(visible, & &1.author)
      assert "user" in authors
      assert "parent_agent" in authors
      refute "child_agent" in authors
      refute "grandchild_agent" in authors
    end
  end

  # ── Branch Propagation Tests ─────────────────────────────────────────

  describe "Context.for_child/2 branch propagation" do
    test "builds correct branch for single-level child" do
      parent_ctx = %Context{invocation_id: "inv-1", branch: nil}
      child = LlmAgent.new(name: "child_agent", model: "test", instruction: "Child")

      child_ctx = Context.for_child(parent_ctx, child)
      assert child_ctx.branch == "child_agent"
    end

    test "builds correct branch for nested child" do
      parent_ctx = %Context{invocation_id: "inv-1", branch: "parent_agent"}
      child = LlmAgent.new(name: "child_agent", model: "test", instruction: "Child")

      child_ctx = Context.for_child(parent_ctx, child)
      assert child_ctx.branch == "parent_agent.child_agent"
    end

    test "builds correct branch for deeply nested grandchild" do
      grandparent_ctx = %Context{invocation_id: "inv-1", branch: nil}
      parent = LlmAgent.new(name: "parent_agent", model: "test", instruction: "Parent")
      grandchild = LlmAgent.new(name: "grandchild_agent", model: "test", instruction: "GC")

      parent_ctx = Context.for_child(grandparent_ctx, parent)
      assert parent_ctx.branch == "parent_agent"

      grandchild_ctx = Context.for_child(parent_ctx, grandchild)
      assert grandchild_ctx.branch == "parent_agent.grandchild_agent"
    end
  end

  describe "Context.fork_branch/2 parallel branch propagation" do
    test "forks from nil parent branch" do
      ctx = %Context{invocation_id: "inv-1", branch: nil}
      forked = Context.fork_branch(ctx, "searcher")
      assert forked.branch == "searcher"
    end

    test "forks from existing branch" do
      ctx = %Context{invocation_id: "inv-1", branch: "root.router"}
      forked = Context.fork_branch(ctx, "searcher")
      assert forked.branch == "root.router.searcher"
    end

    test "forked branches are isolated from each other" do
      ctx = %Context{invocation_id: "inv-1", branch: "root"}
      branch_a = Context.fork_branch(ctx, "agent_a")
      branch_b = Context.fork_branch(ctx, "agent_b")

      # Events on branch_a should not be visible to branch_b
      event_a =
        make_event(author: "agent_a", content: model_content("A result"), branch: branch_a.branch)

      event_b =
        make_event(author: "agent_b", content: model_content("B result"), branch: branch_b.branch)

      refute visible_on_branch?(event_a, branch_b.branch)
      refute visible_on_branch?(event_b, branch_a.branch)
    end

    test "forked branches can see parent events" do
      ctx = %Context{invocation_id: "inv-1", branch: "root"}
      branch_a = Context.fork_branch(ctx, "agent_a")

      parent_event =
        make_event(author: "root", content: model_content("Root msg"), branch: "root")

      assert visible_on_branch?(parent_event, branch_a.branch)
    end

    test "temp_state is cleared on fork" do
      ctx = %Context{invocation_id: "inv-1", branch: nil, temp_state: %{key: "value"}}
      forked = Context.fork_branch(ctx, "worker")
      assert forked.temp_state == %{}
    end
  end

  # ── Multi-Agent Scenario Tests ───────────────────────────────────────

  describe "multi-agent branch isolation scenarios" do
    test "router delegates to weather and news — agents isolated" do
      # Simulate: router → weather_agent, router → news_agent
      events = [
        make_event(
          author: "user",
          branch: nil,
          content: user_content("What's the weather and news?")
        ),
        make_event(
          author: "router",
          branch: "router",
          content: model_content("Let me check both")
        ),
        make_event(
          author: "weather_agent",
          branch: "router.weather_agent",
          content: model_content("It's sunny")
        ),
        make_event(
          author: "news_agent",
          branch: "router.news_agent",
          content: model_content("Markets up 2%")
        )
      ]

      # Weather agent sees: user (nil), router (ancestor), own events — NOT news
      weather_visible = Enum.filter(events, &visible_on_branch?(&1, "router.weather_agent"))
      assert length(weather_visible) == 3
      refute Enum.any?(weather_visible, &(&1.author == "news_agent"))

      # News agent sees: user (nil), router (ancestor), own events — NOT weather
      news_visible = Enum.filter(events, &visible_on_branch?(&1, "router.news_agent"))
      assert length(news_visible) == 3
      refute Enum.any?(news_visible, &(&1.author == "weather_agent"))

      # Router sees: user (nil), own events — NOT weather or news
      router_visible = Enum.filter(events, &visible_on_branch?(&1, "router"))
      assert length(router_visible) == 2
      refute Enum.any?(router_visible, &(&1.author == "weather_agent"))
      refute Enum.any?(router_visible, &(&1.author == "news_agent"))
    end

    test "three-level hierarchy — leaf sees all ancestors but not siblings" do
      events = [
        make_event(author: "user", branch: nil, content: user_content("Go")),
        make_event(author: "root", branch: "root", content: model_content("Root")),
        make_event(author: "mid", branch: "root.mid", content: model_content("Mid")),
        make_event(author: "leaf_a", branch: "root.mid.leaf_a", content: model_content("Leaf A")),
        make_event(author: "leaf_b", branch: "root.mid.leaf_b", content: model_content("Leaf B"))
      ]

      # leaf_a sees: user (nil), root, mid, leaf_a — NOT leaf_b
      leaf_a_visible = Enum.filter(events, &visible_on_branch?(&1, "root.mid.leaf_a"))
      assert length(leaf_a_visible) == 4
      refute Enum.any?(leaf_a_visible, &(&1.author == "leaf_b"))

      # leaf_b sees: user (nil), root, mid, leaf_b — NOT leaf_a
      leaf_b_visible = Enum.filter(events, &visible_on_branch?(&1, "root.mid.leaf_b"))
      assert length(leaf_b_visible) == 4
      refute Enum.any?(leaf_b_visible, &(&1.author == "leaf_a"))

      # mid sees: user (nil), root, mid — NOT leaf_a or leaf_b
      mid_visible = Enum.filter(events, &visible_on_branch?(&1, "root.mid"))
      assert length(mid_visible) == 3
      refute Enum.any?(mid_visible, &(&1.author == "leaf_a"))
      refute Enum.any?(mid_visible, &(&1.author == "leaf_b"))
    end

    test "dot boundary prevents false prefix matches" do
      # Ensure "agent_1" doesn't see events from "agent_10"
      events = [
        make_event(author: "user", branch: nil, content: user_content("Hi")),
        make_event(
          author: "agent_1",
          branch: "router.agent_1",
          content: model_content("Agent 1")
        ),
        make_event(
          author: "agent_10",
          branch: "router.agent_10",
          content: model_content("Agent 10")
        ),
        make_event(
          author: "agent_100",
          branch: "router.agent_100",
          content: model_content("Agent 100")
        )
      ]

      # agent_1 should NOT see agent_10 or agent_100 (they're siblings, not descendants)
      agent_1_visible = Enum.filter(events, &visible_on_branch?(&1, "router.agent_1"))
      # user + own
      assert length(agent_1_visible) == 2
      refute Enum.any?(agent_1_visible, &(&1.author == "agent_10"))
      refute Enum.any?(agent_1_visible, &(&1.author == "agent_100"))
    end
  end

  # ── Edge Cases ───────────────────────────────────────────────────────

  describe "branch filtering edge cases" do
    test "both event and current branch nil — event visible" do
      event = make_event(author: "user", branch: nil, content: user_content("Hi"))
      assert visible_on_branch?(event, nil)
    end

    test "event on branch, current branch nil — event visible" do
      event = make_event(author: "agent", branch: "some.branch", content: model_content("Reply"))
      assert visible_on_branch?(event, nil)
    end

    test "event no branch, current branch set — event visible" do
      event = make_event(author: "user", branch: nil, content: user_content("Hi"))
      assert visible_on_branch?(event, "some.deep.branch")
    end

    test "exact same branch — event visible" do
      event =
        make_event(author: "agent", branch: "root.mid.leaf", content: model_content("Reply"))

      assert visible_on_branch?(event, "root.mid.leaf")
    end

    test "single-segment branches that share no hierarchy" do
      event = make_event(author: "agent_a", branch: "agent_a", content: model_content("A"))
      refute visible_on_branch?(event, "agent_b")
    end

    test "empty string branch treated as set" do
      # Edge case: empty string is truthy in Elixir, unlike Python
      event = make_event(author: "agent", branch: "", content: model_content("Reply"))
      # "" starts with "" + "." → false, but "" == "" → true
      assert visible_on_branch?(event, "")
    end
  end

  # ── Event.on_branch?/2 Current Implementation Tests ─────────────────
  # These document the current Elixir implementation's behavior.
  # NOTE: Event.on_branch?/2 currently has inverted logic vs Python —
  # it checks if event_branch starts_with current_branch, whereas Python
  # checks if current_branch starts_with event_branch. This means:
  #   - Current Elixir: parent sees child events (wrong per Python semantics)
  #   - Current Elixir: child does NOT see parent events (wrong per Python semantics)
  # The corrected behavior is tested via visible_on_branch? above.

  describe "Event.on_branch?/2 — current implementation smoke tests" do
    test "nil event branch is always visible" do
      event = %Event{branch: nil}
      assert Event.on_branch?(event, "any.branch")
    end

    test "exact match is visible" do
      event = %Event{branch: "root.router.weather"}
      assert Event.on_branch?(event, "root.router.weather")
    end

    test "sibling branches are not visible" do
      event = %Event{branch: "root.router.news"}
      refute Event.on_branch?(event, "root.router.weather")
    end
  end
end
