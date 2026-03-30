defmodule ADK.Agent.AgentTransferSystemInstructionsTest do
  @moduledoc """
  Parity tests for Python ADK's
  `tests/unittests/flows/llm_flows/test_agent_transfer_system_instructions.py`.

  Verifies that system instructions are correctly built by `ADK.InstructionCompiler`
  when an agent has sub-agents configured for transfer.

  ## Elixir vs Python parity notes

  Python ADK's `agent_transfer.request_processor` appends a NOTE block to system
  instructions that includes:
  - All directly reachable agents (sub-agents, parent, peers) — alphabetically sorted
  - A `transfer_to_agent` function call instruction
  - A "transfer to parent" instruction if a parent exists

  Elixir's `ADK.InstructionCompiler.transfer_instruction/1` instead produces a
  simpler delegation block listing only `sub_agents`. Key differences:

  1. **Parent/peer agents** — Elixir's `LlmAgent` struct does not have a
     `parent_agent` field at this time. Transfer instructions only reference
     sub-agents.
  2. **Format** — Elixir uses a "can delegate" framing instead of a NOTE block.
  3. **Sorting** — Elixir preserves declaration order (no forced alphabetical sort).
  4. **Per-agent tools** — Elixir generates one `transfer_to_agent_<name>` tool per
     sub-agent (rather than a single `transfer_to_agent` with an enum parameter).

  Tests mirror the Python scenarios where parity exists, and document divergences
  where they don't.
  """

  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.InstructionCompiler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_ctx do
    %ADK.Context{
      invocation_id: "inv-transfer-test",
      session_pid: nil,
      agent: nil,
      user_content: %{text: "test"}
    }
  end

  # ---------------------------------------------------------------------------
  # 1. Transfer instructions include sub-agent names and descriptions
  # ---------------------------------------------------------------------------

  describe "transfer instructions with sub-agents" do
    test "includes sub-agent names in compiled system instructions" do
      sub1 = LlmAgent.new(name: "agent1", model: "test", description: "First sub-agent")
      sub2 = LlmAgent.new(name: "agent2", model: "test", description: "Second sub-agent")

      agent =
        LlmAgent.new(
          name: "main_agent",
          model: "test",
          sub_agents: [sub1, sub2],
          description: "Main agent"
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "agent1"
      assert static =~ "agent2"
    end

    test "includes agent descriptions in transfer instructions" do
      sub = LlmAgent.new(name: "helper", model: "test", description: "Helps with things")

      agent =
        LlmAgent.new(
          name: "main_agent",
          model: "test",
          sub_agents: [sub],
          description: "Delegating agent"
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "helper"
      assert static =~ "Helps with things"
    end

    test "transfer instruction contains delegation guidance" do
      sub =
        LlmAgent.new(name: "specialist", model: "test", description: "Handles specialist tasks")

      agent =
        LlmAgent.new(
          name: "orchestrator",
          model: "test",
          sub_agents: [sub]
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      # Should mention the transfer mechanism (Elixir uses transfer_to_agent tool)
      assert static =~ "transfer_to_agent"
      # Should mention delegation concept
      assert static =~ "delegate"
    end

    test "multiple sub-agents all appear in transfer instructions" do
      sub_agents =
        Enum.map(["alpha", "beta", "gamma"], fn name ->
          LlmAgent.new(name: name, model: "test", description: "Agent #{name}")
        end)

      agent =
        LlmAgent.new(
          name: "coordinator",
          model: "test",
          sub_agents: sub_agents
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "alpha"
      assert static =~ "beta"
      assert static =~ "gamma"
    end

    test "sub-agents without descriptions still appear in transfer instructions" do
      sub = LlmAgent.new(name: "unnamed_sub", model: "test")

      agent =
        LlmAgent.new(
          name: "main_agent",
          model: "test",
          sub_agents: [sub]
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "unnamed_sub"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. No transfer instructions when no sub-agents (mirrors Python's
  #    test_agent_transfer_no_instructions_when_no_transfer_targets)
  # ---------------------------------------------------------------------------

  describe "no transfer instructions when no sub-agents" do
    test "agent with no sub-agents produces no transfer block" do
      agent =
        LlmAgent.new(
          name: "isolated_agent",
          model: "test",
          description: "Isolated agent with no sub-agents"
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      # Python test: no NOTE block and no transfer_to_agent reference
      # Elixir equivalent: no delegation block
      refute compiled =~ "delegate"
      refute compiled =~ "transfer_to_agent"
    end

    test "empty sub_agents list produces no transfer block" do
      agent =
        LlmAgent.new(
          name: "no_subs",
          model: "test",
          sub_agents: []
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      refute static =~ "transfer_to_agent"
    end

    test "compiled instruction without sub-agents remains stable (no side effects)" do
      agent = LlmAgent.new(name: "solo", model: "test", instruction: "Just answer.")
      ctx = make_ctx()

      compiled1 = InstructionCompiler.compile(agent, ctx)
      compiled2 = InstructionCompiler.compile(agent, ctx)

      # Idempotent: multiple compilations produce identical output
      assert compiled1 == compiled2
      refute compiled1 =~ "transfer_to_agent"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Transfer instruction is in the static (cacheable) portion
  #    (mirrors Python: transfer instructions are stable across requests)
  # ---------------------------------------------------------------------------

  describe "transfer instruction placement in static vs dynamic split" do
    test "transfer instruction is in the static portion (suitable for caching)" do
      sub = LlmAgent.new(name: "cached_sub", model: "test", description: "Cacheable sub-agent")

      agent =
        LlmAgent.new(
          name: "main",
          model: "test",
          sub_agents: [sub]
        )

      ctx = make_ctx()
      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      # Transfer instructions belong in the static part (stable across requests)
      assert static =~ "cached_sub"
      assert static =~ "transfer_to_agent"
      # Dynamic part should NOT contain sub-agent transfer info
      refute dynamic =~ "cached_sub"
      refute dynamic =~ "transfer_to_agent"
    end

    test "dynamic instruction (with state vars) is separate from transfer instructions" do
      sub = LlmAgent.new(name: "worker", model: "test", description: "Worker agent")

      agent =
        LlmAgent.new(
          name: "main",
          model: "test",
          instruction: "Handle requests for {user_name}.",
          sub_agents: [sub]
        )

      ctx = make_ctx()
      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      # Transfer instruction is static
      assert static =~ "worker"
      assert static =~ "transfer_to_agent"
      # Agent instruction (with template vars) is dynamic
      assert dynamic =~ "Handle requests"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Transfer instruction with template variable substitution in agent instructions
  #    (mirrors Python: test variable interpolation upon transfer)
  # ---------------------------------------------------------------------------

  describe "system instruction template variable substitution with sub-agents" do
    test "agent instruction variables are substituted when sub-agents present" do
      sub = LlmAgent.new(name: "lookup_agent", model: "test", description: "Looks things up")

      agent =
        LlmAgent.new(
          name: "personalizer",
          model: "test",
          instruction: "Assist user {username} with their query.",
          sub_agents: [sub]
        )

      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "test",
          user_id: "u1",
          session_id: "s-transfer-#{System.unique_integer([:positive])}"
        )

      ADK.Session.put_state(session_pid, "username", "Alice")

      ctx = %ADK.Context{
        invocation_id: "inv-vars",
        session_pid: session_pid,
        agent: agent,
        user_content: %{text: "test"}
      }

      compiled = InstructionCompiler.compile(agent, ctx)

      # Variable substitution works
      assert compiled =~ "Assist user Alice"
      # Transfer instruction also present
      assert compiled =~ "lookup_agent"
      assert compiled =~ "transfer_to_agent"

      GenServer.stop(session_pid)
    end

    test "missing template variables are left as-is when sub-agents present" do
      sub = LlmAgent.new(name: "fallback_agent", model: "test", description: "Fallback handler")

      agent =
        LlmAgent.new(
          name: "templated",
          model: "test",
          instruction: "Assist {missing_var} with lookup.",
          sub_agents: [sub]
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      # Unresolved variable stays as-is
      assert compiled =~ "{missing_var}"
      # Transfer instruction still present
      assert compiled =~ "fallback_agent"
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Per-agent transfer tools are generated correctly
  #    (Elixir uses one tool per sub-agent, not a single parameterized tool)
  # ---------------------------------------------------------------------------

  describe "per-agent transfer tools (Elixir-specific parity)" do
    test "tools_for_sub_agents generates one tool per sub-agent" do
      sub1 = LlmAgent.new(name: "z_agent", model: "test", description: "Last agent")
      sub2 = LlmAgent.new(name: "a_agent", model: "test", description: "First agent")
      sub3 = LlmAgent.new(name: "m_agent", model: "test", description: "Middle agent")

      tools = ADK.Tool.TransferToAgent.tools_for_sub_agents([sub1, sub2, sub3])

      assert length(tools) == 3
      tool_names = Enum.map(tools, & &1.name)
      assert "transfer_to_agent_z_agent" in tool_names
      assert "transfer_to_agent_a_agent" in tool_names
      assert "transfer_to_agent_m_agent" in tool_names
    end

    test "each transfer tool has the correct agent description" do
      sub = LlmAgent.new(name: "specialist", model: "test", description: "Does specialized work")
      [tool] = ADK.Tool.TransferToAgent.tools_for_sub_agents([sub])

      assert tool.name == "transfer_to_agent_specialist"
      assert tool.description =~ "specialist"
      assert tool.description =~ "Does specialized work"
    end

    test "transfer tool func returns transfer signal" do
      sub = LlmAgent.new(name: "target_agent", model: "test", description: "Target")
      [tool] = ADK.Tool.TransferToAgent.tools_for_sub_agents([sub])

      result = tool.func.(nil, %{})
      assert result == {:transfer_to_agent, "target_agent"}
    end

    test "transfer tool enum parameter lists all valid agent names" do
      sub1 = LlmAgent.new(name: "agent_one", model: "test", description: "One")
      sub2 = LlmAgent.new(name: "agent_two", model: "test", description: "Two")

      tools = ADK.Tool.TransferToAgent.tools_for_sub_agents([sub1, sub2])

      # Each tool's enum should include all valid agent names
      Enum.each(tools, fn tool ->
        enum_values = get_in(tool.parameters, [:properties, "agent_name", :enum])
        assert "agent_one" in enum_values
        assert "agent_two" in enum_values
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Full compilation combines all instruction parts correctly
  # ---------------------------------------------------------------------------

  describe "full system instruction compilation with transfers" do
    test "global instruction, identity, transfer, and agent instructions all combine" do
      sub = LlmAgent.new(name: "sub_helper", model: "test", description: "Helper agent")

      agent =
        LlmAgent.new(
          name: "full_agent",
          model: "test",
          description: "The main agent",
          instruction: "Handle the request.",
          global_instruction: "Always be helpful.",
          sub_agents: [sub]
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      # Global instruction
      assert compiled =~ "Always be helpful."
      # Identity (name + description)
      assert compiled =~ "full_agent"
      assert compiled =~ "The main agent"
      # Transfer instruction
      assert compiled =~ "sub_helper"
      assert compiled =~ "transfer_to_agent"
      # Agent instruction
      assert compiled =~ "Handle the request."
    end

    test "isolated agent (no sub-agents, no parent) produces no transfer block" do
      # Mirrors Python's test_agent_transfer_no_instructions_when_no_transfer_targets
      agent =
        LlmAgent.new(
          name: "standalone",
          model: "test",
          instruction: "Answer directly.",
          description: "Standalone agent"
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      # Must have agent instruction
      assert compiled =~ "Answer directly."
      # Must NOT have any transfer-related content
      refute compiled =~ "transfer_to_agent"
      refute compiled =~ "delegate"
    end
  end
end
