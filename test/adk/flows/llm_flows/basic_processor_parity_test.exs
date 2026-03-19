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

defmodule ADK.Flows.LlmFlows.BasicProcessorParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_basic_processor.py`.

  The Python `_BasicLlmRequestProcessor` handles:
  - Setting the model name on the LLM request
  - Setting `response_schema` / `response_mime_type` when the agent has an
    `output_schema` and no tools
  - Skipping response_schema when tools are present (unless model supports it)

  In Elixir ADK, request preprocessing is split across:
  - `LlmAgent.build_request/2` — sets model, messages, tools, instruction
  - `InstructionCompiler` — compiles instruction with output_schema as a
    JSON instruction directive rather than `response_schema`

  This file tests the *equivalent behaviours* through `build_request/2` and
  the Runner + LlmAgent pipeline:
  - Model name propagation to the LLM request
  - Output schema instruction inclusion (no tools)
  - Output schema instruction inclusion (with tools — Elixir always includes)
  - No output schema → no schema directive
  - Tool declarations appear in request when present
  - generate_config passthrough

  Parity divergences (not ported):
  - `response_schema` / `response_mime_type` on config — Elixir uses instruction-
    based schema enforcement, not a config field
  - `can_use_output_schema_with_tools` model check — Elixir always includes
    schema instruction regardless of tool presence
  """

  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.InstructionCompiler
  alias ADK.Tool.FunctionTool

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_ctx(session_pid \\ nil) do
    %ADK.Context{
      invocation_id: "inv-basic-proc-test",
      session_pid: session_pid,
      agent: nil,
      user_content: %{text: "test"}
    }
  end

  defp dummy_tool do
    FunctionTool.new(:dummy_tool,
      description: "A dummy tool for testing",
      func: fn _ctx, %{"query" => q} -> {:ok, "Result: #{q}"} end,
      parameters: %{
        type: "object",
        properties: %{query: %{type: "string", description: "A query"}}
      }
    )
  end

  # ---------------------------------------------------------------------------
  # 1. Model name propagation (mirrors test_sets_model_name)
  # ---------------------------------------------------------------------------

  describe "model name propagation" do
    test "build_request sets model name from agent" do
      agent = LlmAgent.new(name: "test_agent", model: "gemini-1.5-flash", instruction: "Help")
      ctx = make_ctx()

      request = LlmAgent.build_request(ctx, agent)

      assert request.model == "gemini-1.5-flash"
    end

    test "build_request preserves exact model string" do
      agent = LlmAgent.new(name: "test_agent", model: "gemini-2.5-flash", instruction: "Help")
      ctx = make_ctx()

      request = LlmAgent.build_request(ctx, agent)

      assert request.model == "gemini-2.5-flash"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Output schema with no tools (mirrors test_sets_output_schema_when_no_tools)
  # ---------------------------------------------------------------------------

  describe "output schema with no tools" do
    test "output_schema generates JSON instruction via InstructionCompiler" do
      # In Elixir, output_schema is conveyed as an instruction directive
      # via InstructionCompiler, not as response_schema on the request config.
      # build_request uses compile_instruction (no schema); InstructionCompiler
      # adds it at the full-compilation layer.
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "gemini-1.5-flash",
          instruction: "Answer.",
          output_schema: %{type: "object", properties: %{name: %{type: "string"}, value: %{type: "integer"}}},
          tools: []
        )

      ctx = make_ctx()

      # Via InstructionCompiler (full compilation path)
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "Reply with valid JSON matching this schema"
      assert compiled =~ "name"
      assert compiled =~ "value"

      # build_request only includes base instruction (no schema directive)
      request = LlmAgent.build_request(ctx, agent)
      assert request.tools == []
      assert request.model == "gemini-1.5-flash"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Output schema with tools (mirrors test_skips/test_sets_output_schema_when_tools_present)
  # ---------------------------------------------------------------------------

  describe "output schema with tools" do
    test "output_schema instruction is always included via InstructionCompiler" do
      # In Elixir, unlike Python, the schema instruction is always included
      # regardless of tool presence (no can_use_output_schema_with_tools check)
      tool = dummy_tool()

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "gemini-1.5-flash",
          instruction: "Answer.",
          output_schema: %{type: "object", properties: %{name: %{type: "string"}}},
          tools: [tool]
        )

      ctx = make_ctx()

      # InstructionCompiler includes schema regardless of tools
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "Reply with valid JSON matching this schema"
      assert compiled =~ "name"

      # build_request has tool declarations
      request = LlmAgent.build_request(ctx, agent)
      assert length(request.tools) >= 1
      tool_names = Enum.map(request.tools, & &1.name)
      assert "dummy_tool" in tool_names
    end
  end

  # ---------------------------------------------------------------------------
  # 4. No output schema, no tools (mirrors test_no_output_schema_no_tools)
  # ---------------------------------------------------------------------------

  describe "no output schema, no tools" do
    test "no JSON schema instruction when agent has no output_schema" do
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "gemini-1.5-flash",
          instruction: "Be helpful."
        )

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      # Should NOT have schema directive
      refute request.instruction =~ "Reply with valid JSON"

      # No tools
      assert request.tools == []
    end

    test "nil output_schema produces no schema instruction" do
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "gemini-1.5-flash",
          instruction: "Plain.",
          output_schema: nil
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      refute compiled =~ "Reply with valid JSON"
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Tool declarations in request
  # ---------------------------------------------------------------------------

  describe "tool declarations in request" do
    test "tools appear as declarations in the request" do
      tool = dummy_tool()

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test-model",
          instruction: "Help",
          tools: [tool]
        )

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      assert length(request.tools) >= 1
      decl = Enum.find(request.tools, &(&1.name == "dummy_tool"))
      assert decl != nil
      assert decl.description == "A dummy tool for testing"
    end

    test "sub-agent transfer tools are auto-generated" do
      sub = LlmAgent.new(name: "helper", model: "test", instruction: "Assist", description: "Helps")
      agent = LlmAgent.new(name: "root", model: "test", instruction: "Route", sub_agents: [sub])

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      tool_names = Enum.map(request.tools, & &1.name)
      assert "transfer_to_agent_helper" in tool_names
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Agent name in request
  # ---------------------------------------------------------------------------

  describe "agent name in request" do
    test "build_request includes agent_name" do
      agent = LlmAgent.new(name: "my_agent", model: "test-model", instruction: "Help")
      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      assert request.agent_name == "my_agent"
    end
  end

  # ---------------------------------------------------------------------------
  # 7. generate_config passthrough
  # ---------------------------------------------------------------------------

  describe "generate_config passthrough" do
    test "agent generate_config is included in request" do
      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "test-model",
          instruction: "Help",
          generate_config: %{temperature: 0.5, max_output_tokens: 1024}
        )

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      assert request.generate_config.temperature == 0.5
      assert request.generate_config.max_output_tokens == 1024
    end

    test "empty generate_config is not included in request" do
      agent = LlmAgent.new(name: "test_agent", model: "test-model", instruction: "Help")
      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      refute Map.has_key?(request, :generate_config)
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Instruction compilation in build_request
  # ---------------------------------------------------------------------------

  describe "instruction compilation in build_request" do
    test "global_instruction is merged into compiled instruction" do
      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Local instruction.",
          global_instruction: "Global safety rules."
        )

      ctx = make_ctx()
      request = LlmAgent.build_request(ctx, agent)

      assert request.instruction =~ "Global safety rules."
      assert request.instruction =~ "Local instruction."
    end

    test "build_request substitutes state variables in instruction" do
      {:ok, pid} =
        ADK.Session.start_link(
          app_name: "bp_test",
          user_id: "u1",
          session_id: "s-#{System.unique_integer([:positive])}"
        )

      ADK.Session.put_state(pid, "user_name", "Alice")

      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Hello {user_name}, help them."
        )

      ctx = make_ctx(pid)
      request = LlmAgent.build_request(ctx, agent)

      assert request.instruction =~ "Hello Alice, help them."

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # 9. End-to-end: Runner sets model on LLM call (integration)
  # ---------------------------------------------------------------------------

  describe "end-to-end model propagation via Runner" do
    test "Runner passes correct model to LLM.generate" do
      ADK.LLM.Mock.set_responses(["Hello!"])

      agent =
        LlmAgent.new(
          name: "test_agent",
          model: "mock",
          instruction: "Be helpful."
        )

      runner = ADK.Runner.new(app_name: "bp_test", agent: agent)
      events = ADK.Runner.run(runner, "user1", "sess-bp-#{System.unique_integer([:positive])}", "hi")

      # Should have produced at least one model event
      model_events = Enum.filter(events, &(&1.author == "test_agent"))
      assert length(model_events) >= 1

      # Verify the response content
      event = hd(model_events)
      text = get_in(event.content, [:parts, Access.at(0), :text])
      assert text == "Hello!"
    end
  end
end
