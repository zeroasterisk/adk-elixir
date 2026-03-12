defmodule ContextCompilationTest do
  use ExUnit.Case

  describe "instruction compilation" do
    test "single agent produces identity + instruction" do
      agent = ADK.Agent.LlmAgent.new(
        name: "bot",
        model: "test",
        instruction: "Help the user."
      )
      ctx = %ADK.Context{invocation_id: "test-1", agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "You are bot."
      assert result =~ "Help the user."
    end

    test "multi-agent adds transfer instructions" do
      sub = ADK.Agent.LlmAgent.new(
        name: "helper",
        model: "test",
        instruction: "I help.",
        description: "A helpful sub-agent"
      )

      router = ADK.Agent.LlmAgent.new(
        name: "router",
        model: "test",
        instruction: "Route requests.",
        sub_agents: [sub]
      )

      ctx = %ADK.Context{invocation_id: "test-2", agent: router}
      result = ADK.InstructionCompiler.compile(router, ctx)

      assert result =~ "transfer_to_agent"
      assert result =~ "helper"
      assert result =~ "A helpful sub-agent"
    end

    test "state variables are substituted" do
      result = ADK.InstructionCompiler.substitute_vars(
        "Hello {name}, you are in {city}.",
        %{"name" => "Alice", "city" => "Tokyo"}
      )

      assert result == "Hello Alice, you are in Tokyo."
    end

    test "missing variables are left as-is" do
      result = ADK.InstructionCompiler.substitute_vars(
        "Hello {name}!",
        %{}
      )

      assert result == "Hello {name}!"
    end

    test "output schema adds JSON instruction" do
      agent = ADK.Agent.LlmAgent.new(
        name: "structured",
        model: "test",
        instruction: "Extract data.",
        output_schema: %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}
      )
      ctx = %ADK.Context{invocation_id: "test-3", agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)
      assert result =~ "valid JSON"
      assert result =~ "schema"
    end

    test "global instruction appears before agent instruction" do
      agent = ADK.Agent.LlmAgent.new(
        name: "bot",
        model: "test",
        instruction: "Be helpful.",
        global_instruction: "Always be polite."
      )
      ctx = %ADK.Context{invocation_id: "test-4", agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      # Global should come before agent instruction
      global_pos = :binary.match(result, "Always be polite") |> elem(0)
      agent_pos = :binary.match(result, "Be helpful") |> elem(0)
      assert global_pos < agent_pos
    end

    test "effective_tools includes transfer tool for sub-agents" do
      sub = ADK.Agent.LlmAgent.new(
        name: "helper",
        model: "test",
        instruction: "I help."
      )

      router = ADK.Agent.LlmAgent.new(
        name: "router",
        model: "test",
        instruction: "Route.",
        sub_agents: [sub]
      )

      tools = ADK.Agent.LlmAgent.effective_tools(router)
      tool_names = Enum.map(tools, fn t -> ADK.Tool.declaration(t).name end)
      assert Enum.any?(tool_names, &String.starts_with?(&1, "transfer_to_agent"))
    end

    test "dynamic instruction provider (anonymous function)" do
      agent = ADK.Agent.LlmAgent.new(
        name: "dynamic",
        model: "test",
        instruction: fn _ctx -> "I was built dynamically at runtime." end
      )

      ctx = %ADK.Context{invocation_id: "test-5", agent: agent}
      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "dynamically at runtime"
    end
  end
end
