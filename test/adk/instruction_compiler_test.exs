defmodule ADK.InstructionCompilerTest do
  use ExUnit.Case, async: true
  doctest ADK.InstructionCompiler

  describe "substitute_vars/2" do
    test "replaces template variables from state" do
      assert ADK.InstructionCompiler.substitute_vars(
               "Hello {name}, you are {role}.",
               %{"name" => "Alice", "role" => "admin"}
             ) == "Hello Alice, you are admin."
    end

    test "leaves unknown variables unchanged" do
      assert ADK.InstructionCompiler.substitute_vars(
               "Hello {name}, {unknown} here.",
               %{"name" => "Bob"}
             ) == "Hello Bob, {unknown} here."
    end

    test "handles empty state" do
      assert ADK.InstructionCompiler.substitute_vars("No {vars}", %{}) == "No {vars}"
    end

    test "handles atom keys in state" do
      assert ADK.InstructionCompiler.substitute_vars(
               "Hello {name}!",
               %{name: "Charlie"}
             ) == "Hello Charlie!"
    end
  end

  describe "compile/2" do
    test "combines instruction with identity" do
      agent = %ADK.Agent.LlmAgent{
        name: "helper",
        model: "test",
        instruction: "Be helpful.",
        description: "A helpful assistant"
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "You are helper. A helpful assistant"
      assert result =~ "Be helpful."
    end

    test "includes global instruction" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: "Specific task.",
        global_instruction: "Always be polite."
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "Always be polite."
      assert result =~ "Specific task."
    end

    test "includes transfer instructions for sub-agents" do
      sub1 = ADK.Agent.LlmAgent.new(name: "researcher", model: "test", instruction: "Research.", description: "Does research")
      sub2 = ADK.Agent.LlmAgent.new(name: "writer", model: "test", instruction: "Write.", description: "Writes content")

      agent = %ADK.Agent.LlmAgent{
        name: "coordinator",
        model: "test",
        instruction: "Coordinate.",
        sub_agents: [sub1, sub2]
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "transfer_to_agent"
      assert result =~ "researcher: Does research"
      assert result =~ "writer: Writes content"
    end

    test "substitutes variables from session state" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: "Help {user_name} with {topic}."
      }

      {:ok, pid} = ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "compile-test")
      ADK.Session.put_state(pid, "user_name", "Alice")
      ADK.Session.put_state(pid, "topic", "Elixir")

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: pid, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "Help Alice with Elixir."

      GenServer.stop(pid)
    end

    test "includes output schema instruction" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: "Extract data.",
        output_schema: %{type: "object", properties: %{name: %{type: "string"}}}
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "JSON"
      assert result =~ "schema"
    end

    test "handles agent with no description" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: "Help."
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "You are bot."
      assert result =~ "Help."
    end

    test "handles function instruction" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: fn _ctx -> "Dynamic instruction" end
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "Dynamic instruction"
    end
  end
end
