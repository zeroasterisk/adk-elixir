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

defmodule ADK.Agent.LlmAgentOutputSaveTest do
  @moduledoc """
  Parity tests for LLM agent output saving functionality.
  Maps to Python ADK: tests/unittests/agents/test_llm_agent_output_save.py

  Focus areas:
  - output_key saves final response text to session state
  - no output_key → nothing saved
  - partial responses not saved
  - empty/whitespace content not saved
  - author mismatch (agent transfer) not saved
  - case-sensitive name comparison
  - output_schema: JSON parsed, empty chunk no crash
  - multiple text parts concatenated
  - full integration via Runner
  - state persistence across turns
  """
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)
    :ok
  end

  # Helper: build LlmAgent with output_key
  defp agent_with_key(opts \\ []) do
    defaults = [name: "test_agent", model: "test", instruction: "Help", output_key: :result]
    ADK.Agent.LlmAgent.new(Keyword.merge(defaults, opts))
  end

  # Helper: run via Runner, return {events, session_pid}
  defp run_via_runner(agent, message \\ "hello", session_suffix \\ nil) do
    sid = "os-#{session_suffix || :erlang.unique_integer([:positive])}"
    runner = ADK.Runner.new(app_name: "output_save_test", agent: agent)
    events = ADK.Runner.run(runner, "u1", sid, message, stop_session: false)
    {:ok, pid} = ADK.Session.lookup("output_save_test", "u1", sid)
    {events, pid}
  end

  # Helper: check no output saved (handles both nil actions and delta formats)
  defp no_output_in_delta?(event) do
    case event.actions do
      nil -> true
      %{state_delta: %{}} -> true
      %{state_delta: nil} -> true
      %{state_delta: %{added: added}} when added == %{} -> true
      _ -> false
    end
  end

  # ─── 1. Saves final response under output_key ────────────────────────────

  describe "output_key saves to session state" do
    test "saves final response text under atom output_key" do
      ADK.LLM.Mock.set_responses(["Test response"])
      agent = agent_with_key()

      {_events, pid} = run_via_runner(agent)

      assert ADK.Session.get_state(pid, :result) == "Test response"
      GenServer.stop(pid)
    end

    test "saves final response text under string output_key" do
      ADK.LLM.Mock.set_responses(["String key response"])
      agent = agent_with_key(output_key: "my_result")

      {_events, pid} = run_via_runner(agent)

      assert ADK.Session.get_state(pid, "my_result") == "String key response"
      GenServer.stop(pid)
    end
  end

  # ─── 2. No output_key → nothing saved ────────────────────────────────────

  describe "no output_key" do
    test "nothing saved when output_key is nil" do
      ADK.LLM.Mock.set_responses(["Test response"])
      agent = ADK.Agent.LlmAgent.new(name: "test_agent", model: "test", instruction: "Help")

      {events, pid} = run_via_runner(agent)

      final = List.last(events)
      assert no_output_in_delta?(final)
      # Also confirm nothing leaked into session state under :result
      assert ADK.Session.get_state(pid, :result) == nil
      GenServer.stop(pid)
    end
  end

  # ─── 3. Partial responses not saved ──────────────────────────────────────

  describe "partial responses" do
    test "partial response does not trigger output save" do
      ADK.LLM.Mock.set_responses([
        %{partial: true, content: %{role: :model, parts: [%{text: "Partial chunk"}]}}
      ])

      agent = agent_with_key()
      {events, pid} = run_via_runner(agent)

      assert length(events) == 1
      assert ADK.Session.get_state(pid, :result) == nil
      GenServer.stop(pid)
    end
  end

  # ─── 4. Empty / whitespace content not saved ─────────────────────────────

  describe "empty content guard" do
    test "empty string is not saved" do
      agent = agent_with_key()

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: ""}]},
        partial: nil
      }

      result = ADK.Agent.LlmAgent.maybe_save_output_to_state(event, agent)
      assert no_output_in_delta?(result)
    end

    test "whitespace-only is not saved" do
      agent = agent_with_key()

      for ws <- ["   ", "\n", "\t", "  \n  "] do
        event = %ADK.Event{
          invocation_id: "inv-1",
          author: "test_agent",
          content: %{role: :model, parts: [%{text: ws}]},
          partial: nil
        }

        result = ADK.Agent.LlmAgent.maybe_save_output_to_state(event, agent)
        assert no_output_in_delta?(result), "Expected no save for whitespace: #{inspect(ws)}"
      end
    end
  end

  # ─── 5. Author mismatch (agent transfer scenario) ────────────────────────

  describe "author mismatch" do
    test "event from different author is not saved" do
      agent = agent_with_key(name: "agent_a")

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "agent_b",
        content: %{role: :model, parts: [%{text: "Response from B"}]},
        partial: nil
      }

      result = ADK.Agent.LlmAgent.maybe_save_output_to_state(event, agent)
      assert no_output_in_delta?(result)
    end

    test "agent transfer scenario: support_agent ignores billing_agent output" do
      # Python: test_maybe_save_output_to_state_agent_transfer_scenario
      support = agent_with_key(name: "support_agent", output_key: :support_result)

      billing_event = %ADK.Event{
        invocation_id: "inv-1",
        author: "billing_agent",
        content: %{role: :model, parts: [%{text: "Your bill is $100"}]},
        partial: nil
      }

      result = ADK.Agent.LlmAgent.maybe_save_output_to_state(billing_event, support)
      assert no_output_in_delta?(result)
    end
  end

  # ─── 6. Case-sensitive name comparison ───────────────────────────────────

  describe "case sensitivity" do
    test "TestAgent != testagent (case-sensitive)" do
      # Python: test_maybe_save_output_to_state_case_sensitive_names
      agent = agent_with_key(name: "TestAgent")

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "testagent",
        content: %{role: :model, parts: [%{text: "Test response"}]},
        partial: nil
      }

      result = ADK.Agent.LlmAgent.maybe_save_output_to_state(event, agent)
      assert no_output_in_delta?(result)
    end
  end

  # ─── 7. output_schema: JSON parsed, empty final chunk no crash ───────────

  describe "output_schema handling" do
    test "JSON content is parsed when output_schema is set" do
      # Python: test_maybe_save_output_to_state_with_output_schema
      agent = agent_with_key(output_schema: %{"type" => "object"})

      json = ~s({"message": "Hello", "confidence": 0.95})

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: json}]},
        partial: nil
      }

      result = ADK.Agent.LlmAgent.maybe_save_output_to_state(event, agent)
      saved = result.actions.state_delta.added[:result]
      assert saved == %{"message" => "Hello", "confidence" => 0.95}
    end

    test "non-JSON falls back to raw text when schema is set" do
      agent = agent_with_key(output_schema: %{"type" => "object"})

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: "not valid json"}]},
        partial: nil
      }

      result = ADK.Agent.LlmAgent.maybe_save_output_to_state(event, agent)
      assert result.actions.state_delta.added[:result] == "not valid json"
    end

    test "empty final chunk with schema does not crash and saves nothing" do
      # Python: test_maybe_save_output_to_state_handles_empty_final_chunk_with_schema
      agent = agent_with_key(output_schema: %{"type" => "object"})

      for content_text <- ["", "  ", "\n"] do
        event = %ADK.Event{
          invocation_id: "inv-1",
          author: "test_agent",
          content: %{role: :model, parts: [%{text: content_text}]},
          partial: nil
        }

        # Must not raise
        result = ADK.Agent.LlmAgent.maybe_save_output_to_state(event, agent)
        assert no_output_in_delta?(result)
      end
    end
  end

  # ─── 8. Multiple text parts concatenated ─────────────────────────────────

  describe "multiple text parts" do
    test "concatenates all text parts into one value" do
      # Python: test_maybe_save_output_to_state_multiple_parts
      agent = agent_with_key()

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{
          role: :model,
          parts: [%{text: "Hello "}, %{text: "world"}, %{text: "!"}]
        },
        partial: nil
      }

      result = ADK.Agent.LlmAgent.maybe_save_output_to_state(event, agent)
      assert result.actions.state_delta.added[:result] == "Hello world!"
    end
  end

  # ─── 9. Integration: full Runner pipeline ────────────────────────────────

  describe "integration via Runner" do
    test "output_key is persisted to session state through Runner.run" do
      ADK.LLM.Mock.set_responses(["Research results here"])
      agent = agent_with_key(name: "researcher", output_key: :research)
      runner = ADK.Runner.new(app_name: "runner_int_test", agent: agent)

      ADK.Runner.run(runner, "u1", "s-int-1", "Research Elixir", stop_session: false)

      {:ok, pid} = ADK.Session.lookup("runner_int_test", "u1", "s-int-1")
      assert ADK.Session.get_state(pid, :research) == "Research results here"
      GenServer.stop(pid)
    end
  end

  # ─── 10. State persistence across turns ──────────────────────────────────

  describe "state persistence across turns" do
    test "output_key value is overwritten on subsequent runs in same session" do
      ADK.LLM.Mock.set_responses(["First response", "Second response"])
      agent = agent_with_key(name: "persister", output_key: :last_answer)
      runner = ADK.Runner.new(app_name: "persist_test", agent: agent)

      ADK.Runner.run(runner, "u1", "s-persist-1", "first question", stop_session: false)
      {:ok, pid} = ADK.Session.lookup("persist_test", "u1", "s-persist-1")
      assert ADK.Session.get_state(pid, :last_answer) == "First response"

      ADK.Runner.run(runner, "u1", "s-persist-1", "second question", stop_session: false)
      assert ADK.Session.get_state(pid, :last_answer) == "Second response"

      GenServer.stop(pid)
    end
  end
end
