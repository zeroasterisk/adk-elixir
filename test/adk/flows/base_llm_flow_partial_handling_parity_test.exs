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

defmodule ADK.Flows.BaseLlmFlowPartialHandlingParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_base_llm_flow_partial_handling.py`.

  The Python tests verify that `BaseLlmFlow.run_async` breaks the iteration loop
  under these conditions:

  1. The LLM returns a partial response (`partial=True`)
  2. The LLM returns a final (non-partial) response
  3. The LLM returns an empty response (`content=None`) — filtered, no events
  4. Multiple queued responses with the first being partial — only first is emitted

  In Elixir, the equivalent behaviour lives in `ADK.Agent.LlmAgent.do_run/3`,
  which orchestrates the LLM call loop. These tests verify:

  - `partial: true` events are emitted and the loop halts (no tool-call recursion)
  - `partial: false` (final) events are emitted and the loop halts
  - `content: nil` (empty) responses produce zero events
  - On the first partial response, subsequent queued mock responses are NOT consumed

  Parity divergences (Python-only, not ported):
  - `BaseLlmFlow` class hierarchy — Elixir uses `LlmAgent.do_run/3` directly
  - `InvocationContext` creation via `testing_utils` — Elixir uses `Runner.run/5`
  - Async iteration (`async for`) — Elixir is synchronous list collection
  - `LlmResponse(error_code=FinishReason.STOP)` — Elixir uses plain maps; no
    explicit finish-reason field needed for final-response detection
  """

  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.Runner

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ── Helper ────────────────────────────────────────────────────────────

  defp run_agent(responses) do
    ADK.LLM.Mock.set_responses(responses)

    agent =
      LlmAgent.new(
        name: "test_agent",
        model: "test",
        instruction: "You are a helpful assistant."
      )

    runner = Runner.new(app_name: "partial_test", agent: agent)
    sid = "s-#{System.unique_integer([:positive])}"

    # Filter to only agent events (not the user echo event)
    events = Runner.run(runner, "u1", sid, "test message")
    Enum.filter(events, &(&1.author == "test_agent"))
  end

  defp get_text(event) do
    parts = event.content[:parts] || event.content["parts"] || []

    Enum.find_value(parts, fn
      %{text: t} -> t
      %{"text" => t} -> t
      _ -> nil
    end)
  end

  # ── Tests ─────────────────────────────────────────────────────────────

  @doc """
  Python: test_run_async_breaks_on_partial_event

  When the LLM returns a partial response, the flow should emit exactly one event
  with `partial: true`.
  """
  test "breaks on partial event — emits one partial event" do
    events =
      run_agent([
        %{
          partial: true,
          content: %{role: :model, parts: [%{text: "Partial response"}]}
        }
      ])

    assert length(events) == 1
    assert hd(events).partial == true
    assert get_text(hd(events)) == "Partial response"
  end

  @doc """
  Python: test_run_async_breaks_on_final_response

  When the LLM returns a non-partial (final) response, the flow should emit
  exactly one event with `partial: false` (or falsy).
  """
  test "breaks on final response — emits one non-partial event" do
    events =
      run_agent([
        %{
          partial: false,
          content: %{role: :model, parts: [%{text: "Final response"}]}
        }
      ])

    assert length(events) == 1
    refute hd(events).partial
    assert get_text(hd(events)) == "Final response"
  end

  @doc """
  Python: test_run_async_breaks_on_no_last_event

  When the LLM returns an empty response (content: nil), an error event should be
  emitted to notify the user.
  """
  test "empty content response produces error event" do
    events = run_agent([%{partial: false, content: nil}])

    assert length(events) == 1
    assert hd(events).error == :nil_content
  end

  @doc """
  Python: test_run_async_breaks_on_first_partial_response

  When multiple responses are queued, the flow should break on the FIRST partial
  response. Subsequent responses in the queue should not be consumed.
  """
  test "breaks on first partial — subsequent responses not consumed" do
    # Only the first partial should be emitted; the others should remain unused
    events =
      run_agent([
        %{
          partial: true,
          content: %{role: :model, parts: [%{text: "Partial response"}]}
        },
        %{
          partial: false,
          content: %{role: :model, parts: [%{text: "Non-partial response"}]}
        },
        %{
          partial: true,
          content: %{role: :model, parts: [%{text: "Final partial response"}]}
        }
      ])

    # Only the first partial event should have been consumed
    assert length(events) == 1
    assert hd(events).partial == true
    assert get_text(hd(events)) == "Partial response"

    # Remaining responses should still be in the mock queue
    remaining = Process.get(:adk_mock_responses)
    assert length(remaining) == 2
  end
end
