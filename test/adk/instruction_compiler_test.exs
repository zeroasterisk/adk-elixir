defmodule ADK.InstructionCompilerTest.Helpers do
  @moduledoc "Test helpers for InstructionProvider tests."

  def static_provider(_ctx), do: "MFA static instruction"

  # Called as: apply(mod, :provider_with_args, [ctx, "extra"])
  # i.e. provider_with_args/2 — extra is the single extra arg
  def provider_with_args(_ctx, arg), do: "MFA with args: #{arg}"

  # Called as: apply(mod, :provider_with_args, [ctx, "arg1", "arg2"])
  # i.e. provider_with_args/3 — two extra args
  def provider_with_args(_ctx, a, b), do: "MFA with args: #{a} #{b}"
end

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

    test "function instruction receives context" do
      agent = %ADK.Agent.LlmAgent{
        name: "ctx-bot",
        model: "test",
        instruction: fn ctx ->
          "Invocation: #{ctx.invocation_id}"
        end
      }

      ctx = %ADK.Context{invocation_id: "inv-42", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "Invocation: inv-42"
    end

    test "function instruction result still gets template vars substituted" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: fn _ctx -> "Hello {user_name}!" end
      }

      {:ok, pid} = ADK.Session.start_link(app_name: "test", user_id: "u1", session_id: "fn-tmpl-test")
      ADK.Session.put_state(pid, "user_name", "Alice")

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: pid, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "Hello Alice!"
      GenServer.stop(pid)
    end

    test "MFA tuple {mod, fun} instruction" do
      agent = %ADK.Agent.LlmAgent{
        name: "mfa-bot",
        model: "test",
        instruction: {ADK.InstructionCompilerTest.Helpers, :static_provider}
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "MFA static instruction"
    end

    test "MFA tuple {mod, fun, args} instruction" do
      agent = %ADK.Agent.LlmAgent{
        name: "mfa-args-bot",
        model: "test",
        instruction: {ADK.InstructionCompilerTest.Helpers, :provider_with_args, ["extra"]}
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "MFA with args: extra"
    end

    test "function global_instruction is resolved" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: "Agent task.",
        global_instruction: fn _ctx -> "Dynamic global policy." end
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "Dynamic global policy."
      assert result =~ "Agent task."
    end

    test "MFA global_instruction is resolved" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: "Agent task.",
        global_instruction: {ADK.InstructionCompilerTest.Helpers, :static_provider}
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "MFA static instruction"
      assert result =~ "Agent task."
    end

    test "global_instruction provider receives context" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: "Task.",
        global_instruction: fn ctx -> "Global for #{ctx.invocation_id}" end
      }

      ctx = %ADK.Context{invocation_id: "inv-99", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "Global for inv-99"
    end

    test "function instruction returning non-binary is coerced" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: fn _ctx -> 42 end
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      result = ADK.InstructionCompiler.compile(agent, ctx)

      assert result =~ "42"
    end

    test "function instruction that raises returns empty string (graceful degradation)" do
      agent = %ADK.Agent.LlmAgent{
        name: "bot",
        model: "test",
        instruction: fn _ctx -> raise "boom" end
      }

      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: agent}

      # Should not raise — degraded gracefully
      result = ADK.InstructionCompiler.compile(agent, ctx)
      assert is_binary(result)
    end
  end

  describe "resolve_provider/2" do
    test "nil returns nil" do
      assert ADK.InstructionCompiler.resolve_provider(nil, nil) == nil
    end

    test "binary returns as-is" do
      assert ADK.InstructionCompiler.resolve_provider("hello", nil) == "hello"
    end

    test "1-arity function called with ctx" do
      ctx = %ADK.Context{invocation_id: "x", session_pid: nil, agent: nil}
      result = ADK.InstructionCompiler.resolve_provider(fn c -> "id=#{c.invocation_id}" end, ctx)
      assert result == "id=x"
    end

    test "{mod, fun} MFA called with ctx" do
      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: nil}
      result = ADK.InstructionCompiler.resolve_provider({ADK.InstructionCompilerTest.Helpers, :static_provider}, ctx)
      assert result == "MFA static instruction"
    end

    test "{mod, fun, extra_args} MFA called with ctx prepended" do
      ctx = %ADK.Context{invocation_id: "inv-1", session_pid: nil, agent: nil}
      result = ADK.InstructionCompiler.resolve_provider({ADK.InstructionCompilerTest.Helpers, :provider_with_args, ["arg1", "arg2"]}, ctx)
      assert result == "MFA with args: arg1 arg2"
    end

    test "non-binary return coerced to string" do
      result = ADK.InstructionCompiler.resolve_provider(fn _ctx -> :atom_value end, nil)
      assert result == "atom_value"
    end

    test "raising provider returns empty string" do
      result = ADK.InstructionCompiler.resolve_provider(fn _ctx -> raise "oops" end, nil)
      assert result == ""
    end

    test "unknown provider type returns nil with warning" do
      # Integer or other unexpected type
      result = ADK.InstructionCompiler.resolve_provider(123, nil)
      assert is_nil(result)
    end
  end
end
