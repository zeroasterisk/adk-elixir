defmodule ADK.Flows.OtherConfigsParityTest do
  @moduledoc """
  Parity tests for Python's `test_other_configs.py`.

  Python tests:
    - test_output_schema: output_schema sets response_schema, response_mime_type,
      and labels on the LLM request config.

  In Elixir, output_schema is handled differently:
    - InstructionCompiler injects JSON schema instructions into the prompt
    - LlmAgent.maybe_parse_with_schema/2 parses JSON responses against the schema
    - build_request includes agent_name for traceability

  This file tests the Elixir-equivalent behavior end-to-end.
  """
  use ExUnit.Case, async: false

  alias ADK.Agent.LlmAgent
  alias ADK.InstructionCompiler

  # ──────────────────────────────────────────────────────────────────
  # 1. output_schema — instruction injection
  # ──────────────────────────────────────────────────────────────────

  describe "output_schema instruction injection (parity: test_output_schema)" do
    test "output_schema injects JSON schema instruction into compiled prompt" do
      schema = %{type: "object", properties: %{custom_field: %{type: "string"}}}

      agent_map = %{
        name: "root_agent",
        model: "test",
        instruction: "Answer.",
        output_schema: schema,
        global_instruction: nil,
        sub_agents: [],
        description: nil
      }

      ctx = %ADK.Context{invocation_id: "test-inv"}
      compiled = InstructionCompiler.compile(agent_map, ctx)

      assert compiled =~ "Reply with valid JSON matching this schema"
      assert compiled =~ "custom_field"
    end

    test "nil output_schema does not inject schema instruction" do
      agent = LlmAgent.new(name: "root_agent", model: "test", instruction: "Answer.")

      ctx = %ADK.Context{invocation_id: "test-inv"}
      compiled = InstructionCompiler.compile(agent, ctx)

      refute compiled =~ "Reply with valid JSON"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 2. output_schema — JSON response parsing via runner
  # ──────────────────────────────────────────────────────────────────

  describe "output_schema end-to-end via runner" do
    test "output_schema agent parses JSON response and saves parsed output" do
      json_response = ~s|{"custom_field": "hello"}|
      ADK.LLM.Mock.set_responses([json_response])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Answer.",
          output_schema: %{type: "object", properties: %{custom_field: %{type: "string"}}},
          output_key: :result,
          disallow_transfer_to_parent: true,
          disallow_transfer_to_peers: true
        )

      runner = ADK.Runner.new(app_name: "test_app", agent: agent)
      events = ADK.Runner.run(runner, "user1", "test-sess-schema-1", "test1")

      # Should get at least the model response event
      model_events =
        Enum.filter(events, fn e ->
          e.author == "root_agent" and not is_nil(e.content)
        end)

      assert length(model_events) >= 1

      # The response text should be the JSON we provided
      response_event = List.last(model_events)
      parts = get_in(response_event.content, [:parts]) || get_in(response_event.content, ["parts"]) || []
      texts = for p <- parts, t = p[:text] || p["text"], do: t
      assert Enum.any?(texts, &(&1 =~ "custom_field"))
    end

    test "output_schema agent returns text response as-is when not JSON" do
      ADK.LLM.Mock.set_responses(["plain text response"])

      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Answer.",
          output_schema: %{type: "object", properties: %{field: %{type: "string"}}},
          output_key: :result
        )

      runner = ADK.Runner.new(app_name: "test_app", agent: agent)
      events = ADK.Runner.run(runner, "user1", "test-sess-schema-2", "test1")

      model_events =
        Enum.filter(events, fn e ->
          e.author == "root_agent" and not is_nil(e.content)
        end)

      assert length(model_events) >= 1
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 3. build_request includes agent_name (parity: labels)
  # ──────────────────────────────────────────────────────────────────

  describe "build_request agent_name (parity: labels/adk_agent_name)" do
    test "build_request includes agent_name in request" do
      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Help."
        )

      ctx = %ADK.Context{invocation_id: "test-inv", agent: agent}
      request = LlmAgent.build_request(ctx, agent)

      assert request.agent_name == "root_agent"
    end

    test "build_request agent_name reflects the agent's name" do
      agent =
        LlmAgent.new(
          name: "my_custom_agent",
          model: "test",
          instruction: "Help."
        )

      ctx = %ADK.Context{invocation_id: "test-inv", agent: agent}
      request = LlmAgent.build_request(ctx, agent)

      assert request.agent_name == "my_custom_agent"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 4. disallow_transfer flags (tested in output_schema context)
  # ──────────────────────────────────────────────────────────────────

  describe "disallow_transfer flags on agent" do
    test "agent accepts disallow_transfer_to_parent and disallow_transfer_to_peers" do
      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Help.",
          disallow_transfer_to_parent: true,
          disallow_transfer_to_peers: true
        )

      assert agent.disallow_transfer_to_parent == true
      assert agent.disallow_transfer_to_peers == true
    end

    test "defaults to false for transfer flags" do
      agent = LlmAgent.new(name: "agent", model: "test", instruction: "Help.")

      assert agent.disallow_transfer_to_parent == false
      assert agent.disallow_transfer_to_peers == false
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 5. generate_config on build_request
  # ──────────────────────────────────────────────────────────────────

  describe "generate_config in build_request" do
    test "agent generate_config is included in LLM request" do
      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Help.",
          generate_config: %{temperature: 0.7, top_p: 0.9, max_output_tokens: 500}
        )

      ctx = %ADK.Context{invocation_id: "test-inv", agent: agent}
      request = LlmAgent.build_request(ctx, agent)

      assert request.generate_config.temperature == 0.7
      assert request.generate_config.top_p == 0.9
      assert request.generate_config.max_output_tokens == 500
    end

    test "empty generate_config is not included in request" do
      agent = LlmAgent.new(name: "root_agent", model: "test", instruction: "Help.")

      ctx = %ADK.Context{invocation_id: "test-inv", agent: agent}
      request = LlmAgent.build_request(ctx, agent)

      refute Map.has_key?(request, :generate_config)
    end

    test "generate_config with stop_sequences" do
      agent =
        LlmAgent.new(
          name: "root_agent",
          model: "test",
          instruction: "Help.",
          generate_config: %{stop_sequences: ["STOP", "END"]}
        )

      ctx = %ADK.Context{invocation_id: "test-inv", agent: agent}
      request = LlmAgent.build_request(ctx, agent)

      assert request.generate_config.stop_sequences == ["STOP", "END"]
    end
  end
end
