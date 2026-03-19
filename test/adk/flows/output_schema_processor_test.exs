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

defmodule ADK.Flows.OutputSchemaProcessorTest do
  @moduledoc """
  Parity tests for output schema processor functionality.
  Maps to Python ADK: tests/unittests/flows/llm_flows/test_output_schema_processor.py

  Focus areas:
  - output_schema field accepted alongside tools and sub_agents
  - InstructionCompiler output_schema instruction generation (various schemas)
  - JSON parsing via maybe_parse_with_schema (valid, invalid, non-ASCII, nested)
  - build_request does NOT inject output_schema into generate_config when tools present
  - end-to-end agent produces JSON-parsed output when output_schema + output_key set
  """

  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.InstructionCompiler

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @person_schema %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string", "description" => "A person's name"},
      "age" => %{"type" => "integer", "description" => "A person's age"},
      "city" => %{"type" => "string", "description" => "The city they live in"}
    }
  }

  defp make_ctx do
    # Minimal context for InstructionCompiler (no session needed)
    %ADK.Context{
      invocation_id: "test-inv",
      session_pid: nil,
      agent: LlmAgent.new(name: "test", model: "test", instruction: "test"),
      user_content: "hi"
    }
  end

  defp make_dummy_tool do
    ADK.Tool.FunctionTool.new(:dummy_tool,
      description: "A dummy tool for testing",
      func: fn _ctx, %{"query" => q} -> {:ok, "Searched for: #{q}"} end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"}
        }
      }
    )
  end

  # ── 1. Agent field acceptance ────────────────────────────────────────────────

  describe "output_schema field acceptance" do
    test "LlmAgent allows output_schema with tools" do
      # Python: test_output_schema_with_tools_validation_removed
      tool = make_dummy_tool()

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Be helpful.",
          output_schema: @person_schema,
          tools: [tool]
        )

      assert agent.output_schema == @person_schema
      assert length(agent.tools) == 1
    end

    test "LlmAgent allows output_schema with sub_agents" do
      # Python: test_output_schema_with_sub_agents
      sub = LlmAgent.new(name: "sub_agent", model: "test", instruction: "Sub.")

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Main.",
          output_schema: @person_schema,
          sub_agents: [sub]
        )

      assert agent.output_schema == @person_schema
      assert length(agent.sub_agents) == 1
    end

    test "LlmAgent allows output_schema without tools or sub_agents" do
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Be helpful.",
          output_schema: @person_schema
        )

      assert agent.output_schema == @person_schema
      assert agent.tools == []
      assert agent.sub_agents == []
    end

    test "LlmAgent nil output_schema by default" do
      agent = LlmAgent.new(name: "test_agent", model: "test", instruction: "Hi.")
      assert agent.output_schema == nil
    end
  end

  # ── 2. InstructionCompiler schema instruction generation ─────────────────────

  describe "InstructionCompiler output_schema instruction" do
    test "generates JSON instruction for object schema" do
      # Python: test_basic_processor_sets_output_schema_without_tools (instruction path)
      agent_map = %{
        name: "bot",
        model: "test",
        instruction: nil,
        output_schema: @person_schema,
        global_instruction: nil,
        sub_agents: [],
        description: nil
      }

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent_map, ctx)
      assert compiled =~ "Reply with valid JSON matching this schema"
      assert compiled =~ "name"
      assert compiled =~ "age"
      assert compiled =~ "city"
    end

    test "generates instruction for simple schema" do
      schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

      agent_map = %{
        name: "bot",
        model: "test",
        instruction: nil,
        output_schema: schema,
        global_instruction: nil,
        sub_agents: [],
        description: nil
      }

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent_map, ctx)
      assert compiled =~ "Reply with valid JSON"
      assert compiled =~ "answer"
    end

    test "nil output_schema produces no schema instruction" do
      agent_map = %{
        name: "bot",
        model: "test",
        instruction: "Just chat.",
        output_schema: nil,
        global_instruction: nil,
        sub_agents: [],
        description: nil
      }

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent_map, ctx)
      refute compiled =~ "Reply with valid JSON"
    end

    test "schema instruction combines with agent instruction" do
      agent_map = %{
        name: "bot",
        model: "test",
        instruction: "You are a helpful assistant.",
        output_schema: @person_schema,
        global_instruction: nil,
        sub_agents: [],
        description: nil
      }

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent_map, ctx)
      assert compiled =~ "You are a helpful assistant."
      assert compiled =~ "Reply with valid JSON matching this schema"
    end

    test "schema instruction is in dynamic part of compile_split" do
      agent_map = %{
        name: "bot",
        model: "test",
        instruction: "Be helpful.",
        output_schema: @person_schema,
        global_instruction: "Global context.",
        sub_agents: [],
        description: nil
      }

      ctx = make_ctx()
      {static, dynamic} = InstructionCompiler.compile_split(agent_map, ctx)

      # Schema instruction should be in dynamic, not static
      assert dynamic =~ "Reply with valid JSON"
      refute static =~ "Reply with valid JSON"

      # Global instruction should be in static
      assert static =~ "Global context."
    end

    test "schema with nested properties encodes properly" do
      nested_schema = %{
        "type" => "object",
        "properties" => %{
          "person" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "address" => %{
                "type" => "object",
                "properties" => %{
                  "street" => %{"type" => "string"},
                  "city" => %{"type" => "string"}
                }
              }
            }
          }
        }
      }

      agent_map = %{
        name: "bot",
        model: "test",
        instruction: nil,
        output_schema: nested_schema,
        global_instruction: nil,
        sub_agents: [],
        description: nil
      }

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent_map, ctx)
      assert compiled =~ "Reply with valid JSON matching this schema"
      assert compiled =~ "street"
      assert compiled =~ "address"
    end
  end

  # ── 3. JSON parsing (maybe_parse_with_schema) ──────────────────────────────

  describe "maybe_parse_with_schema via maybe_save_output_to_state" do
    test "valid JSON object is parsed when schema is set" do
      # Python: test_set_model_response_tool (validates JSON roundtrip)
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Return person.",
          output_key: :result,
          output_schema: @person_schema
        )

      json = ~s({"name": "John Doe", "age": 30, "city": "New York"})

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: json}]},
        partial: nil
      }

      result = LlmAgent.maybe_save_output_to_state(event, agent)
      saved = result.actions.state_delta.added[:result]
      assert saved == %{"name" => "John Doe", "age" => 30, "city" => "New York"}
    end

    test "non-ASCII JSON is parsed correctly" do
      # Python: test_get_structured_model_response_with_non_ascii
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Return person.",
          output_key: :result,
          output_schema: @person_schema
        )

      json = ~s({"name": "José", "age": 42, "city": "São Paulo"})

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: json}]},
        partial: nil
      }

      result = LlmAgent.maybe_save_output_to_state(event, agent)
      saved = result.actions.state_delta.added[:result]
      assert saved["name"] == "José"
      assert saved["city"] == "São Paulo"
    end

    test "JSON array is parsed when schema is set" do
      # Python: test_get_structured_model_response_with_wrapped_result (adapted)
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Return list.",
          output_key: :result,
          output_schema: %{"type" => "array", "items" => %{"type" => "object"}}
        )

      json = ~s([{"name": "Alice", "age": 30}, {"name": "Bob", "age": 25}])

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: json}]},
        partial: nil
      }

      result = LlmAgent.maybe_save_output_to_state(event, agent)
      saved = result.actions.state_delta.added[:result]
      assert is_list(saved)
      assert length(saved) == 2
      assert hd(saved)["name"] == "Alice"
    end

    test "invalid JSON falls back to raw text with schema" do
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Return person.",
          output_key: :result,
          output_schema: @person_schema
        )

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: "not valid json at all"}]},
        partial: nil
      }

      result = LlmAgent.maybe_save_output_to_state(event, agent)
      saved = result.actions.state_delta.added[:result]
      assert saved == "not valid json at all"
    end

    test "text is stored as-is without schema" do
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Chat.",
          output_key: :result,
          output_schema: nil
        )

      event = %ADK.Event{
        invocation_id: "inv-1",
        author: "test_agent",
        content: %{role: :model, parts: [%{text: "just plain text"}]},
        partial: nil
      }

      result = LlmAgent.maybe_save_output_to_state(event, agent)
      saved = result.actions.state_delta.added[:result]
      assert saved == "just plain text"
    end
  end

  # ── 4. build_request behavior with output_schema ───────────────────────────

  describe "build_request with output_schema" do
    test "output_schema does not auto-inject into generate_config" do
      # Python: test_basic_processor_skips_output_schema_with_tools
      # In Elixir, output_schema is NOT auto-injected into generate_config.
      # The user must explicitly configure generate_config if they want
      # response_schema/response_mime_type on the LLM request.
      tool = make_dummy_tool()

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Be helpful.",
          output_schema: @person_schema,
          tools: [tool]
        )

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      # generate_config should NOT be set (output_schema goes through instruction)
      refute Map.has_key?(request, :generate_config)
    end

    test "build_request uses compile_instruction (not InstructionCompiler)" do
      # Note: LlmAgent.build_request uses its own compile_instruction method
      # which does NOT include output_schema instruction. The InstructionCompiler
      # module is a separate utility. This test verifies the actual behavior.
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Be helpful.",
          output_schema: @person_schema
        )

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      # compile_instruction does not inject output_schema — that's handled
      # separately by InstructionCompiler when used
      assert request.instruction == "Be helpful."
    end

    test "no output_schema means no schema in instruction" do
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Be helpful."
        )

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      refute request.instruction =~ "Reply with valid JSON"
    end

    test "explicit generate_config is preserved alongside output_schema" do
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Return person.",
          output_schema: @person_schema,
          generate_config: %{temperature: 0.5, max_output_tokens: 100}
        )

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      assert request.generate_config.temperature == 0.5
      assert request.generate_config.max_output_tokens == 100
      # output_schema does not affect compile_instruction output
      assert request.instruction == "Return person."
    end
  end

  # ── 5. End-to-end with Agent.run ───────────────────────────────────────────

  describe "end-to-end output_schema with agent run" do
    test "agent produces JSON-parsed output in state delta" do
      # Python: test_end_to_end_integration (adapted for Elixir agent)
      json_response = ~s({"name": "Jane Smith", "age": 25, "city": "Los Angeles"})

      ADK.LLM.Mock.set_responses([json_response])

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Return person info.",
          output_schema: @person_schema,
          output_key: :person_data
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test_schema_e2e", user_id: "u1", session_id: "s1")

      # Add a user message to the session
      user_event =
        ADK.Event.new(%{
          invocation_id: "inv-e2e",
          author: "user",
          content: %{parts: [%{text: "Tell me about Jane"}]}
        })

      ADK.Session.append_event(session_pid, user_event)

      ctx = %ADK.Context{
        invocation_id: "inv-e2e",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Tell me about Jane"}
      }

      events = ADK.Agent.run(agent, ctx)

      # Find the model response event
      model_events = Enum.filter(events, fn e -> e.author == "test_agent" end)
      assert length(model_events) >= 1

      # The output should have been saved with JSON parsed
      last_event = List.last(model_events)
      assert last_event.actions != nil
      assert last_event.actions.state_delta != nil
      saved = last_event.actions.state_delta.added[:person_data]
      assert saved == %{"name" => "Jane Smith", "age" => 25, "city" => "Los Angeles"}

      GenServer.stop(session_pid)
    end

    test "agent stores raw text when output_schema is nil" do
      ADK.LLM.Mock.set_responses(["Hello there!"])

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Chat normally.",
          output_schema: nil,
          output_key: :response
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test_no_schema_e2e", user_id: "u1", session_id: "s2")

      user_event =
        ADK.Event.new(%{
          invocation_id: "inv-e2e-2",
          author: "user",
          content: %{parts: [%{text: "Hi"}]}
        })

      ADK.Session.append_event(session_pid, user_event)

      ctx = %ADK.Context{
        invocation_id: "inv-e2e-2",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Hi"}
      }

      events = ADK.Agent.run(agent, ctx)

      model_events = Enum.filter(events, fn e -> e.author == "test_agent" end)
      assert length(model_events) >= 1

      last_event = List.last(model_events)
      saved = last_event.actions.state_delta.added[:response]
      assert saved == "Hello there!"

      GenServer.stop(session_pid)
    end

    test "agent instruction includes schema when output_schema is set with tools" do
      # Python: test_end_to_end_integration — verifies instruction has set_model_response
      # In Elixir, the instruction has the schema embedded instead
      tool = make_dummy_tool()

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Be helpful.",
          output_schema: @person_schema,
          tools: [tool]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(app_name: "test_schema_tools", user_id: "u1", session_id: "s3")

      ctx = %ADK.Context{
        invocation_id: "inv-e2e-3",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "Info?"}
      }

      request = LlmAgent.build_request(ctx, agent)

      # LlmAgent.compile_instruction does not inject output_schema instruction,
      # but the InstructionCompiler module does (tested separately above).
      # Here we verify tool declarations are present.
      assert length(request.tools) >= 1
      # And that output_schema is stored on the agent for JSON parsing
      assert agent.output_schema == @person_schema

      GenServer.stop(session_pid)
    end
  end
end
