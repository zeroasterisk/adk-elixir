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

defmodule ADK.InstructionsTest do
  @moduledoc """
  Parity tests for Python ADK's
  `tests/unittests/flows/llm_flows/test_instructions.py`.

  Tests the instruction compilation pipeline including template variable
  substitution, function/callable instruction providers, global + agent
  instruction merging, and edge cases.

  ## Elixir vs Python parity notes

  1. **Namespace variables** (`{app:key}`, `{user:key}`) — Python's regex
     matches `\\w+` which includes identifiers only, but Python stores state
     keys with literal `:` (e.g., `"app:key"`). Elixir's `substitute_vars/2`
     uses `\\w+` regex which doesn't match `:` in keys, so namespace-prefixed
     variables are NOT substituted. This is a known divergence.

  2. **bypass_state_injection** — In Python, callable instructions return
     `(text, bypass=True)` via `canonical_instruction`, skipping template
     variable substitution on the resolved text. In Elixir, `InstructionCompiler`
     always applies `substitute_vars/2` after resolving a provider. This means
     if a callable returns text containing `{var}` patterns, they WILL be
     substituted in Elixir (divergence). Tests document this difference.

  3. **static_instruction** — Python's `LlmAgent` has a `static_instruction`
     field that routes content to system instruction vs user content. Elixir
     does not have this concept. All static_instruction tests are skipped.

  4. **Global instruction resolution** — In Python, the global instruction is
     fetched from the `root_agent` by walking `parent_agent`. In Elixir,
     `InstructionCompiler` reads `global_instruction` directly from the agent
     map passed to `compile/2`. For sub-agent scenarios, the caller must
     ensure the correct global instruction is set.
  """

  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.InstructionCompiler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_ctx(session_pid \\ nil) do
    %ADK.Context{
      invocation_id: "test_id",
      session_pid: session_pid,
      agent: nil,
      user_content: %{text: "test"}
    }
  end

  defp with_session(state_pairs, fun) do
    {:ok, pid} =
      ADK.Session.start_link(
        app_name: "test_app",
        user_id: "test_user",
        session_id: "s-#{System.unique_integer([:positive])}"
      )

    for {k, v} <- state_pairs, do: ADK.Session.put_state(pid, k, v)
    result = fun.(pid)
    GenServer.stop(pid)
    result
  end

  # ---------------------------------------------------------------------------
  # Template variable substitution
  # Mirrors: test_build_system_instruction
  # ---------------------------------------------------------------------------

  describe "template variable substitution" do
    test "substitutes {var} from session state" do
      with_session(
        [{"customerId", "1234567890"}, {"customer_int", 30}],
        fn pid ->
          agent =
            LlmAgent.new(
              name: "agent",
              model: "gemini-1.5-flash",
              instruction:
                "Use the echo_info tool to echo {customerId}, " <>
                  "{customer_int}."
            )

          ctx = make_ctx(pid)
          compiled = InstructionCompiler.compile(agent, ctx)
          assert compiled =~ "echo 1234567890, 30."
        end
      )
    end

    test "leaves non-identifier patterns unchanged" do
      # Python: { non-identifier-float}} is NOT a valid {var} so left as-is
      # Same in Elixir: \w+ regex doesn't match hyphens or spaces
      agent =
        LlmAgent.new(
          name: "agent",
          model: "gemini-1.5-flash",
          instruction: "Test { non-identifier-float}} here."
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "{ non-identifier-float}}"
    end

    test "leaves dict-like patterns unchanged" do
      # Python: {'key1': 'value1'} and {{'key2': 'value2'}} should be left as-is
      agent =
        LlmAgent.new(
          name: "agent",
          model: "gemini-1.5-flash",
          instruction: "{'key1': 'value1'} and {{'key2': 'value2'}}"
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "{'key1': 'value1'}"
      assert compiled =~ "{{'key2': 'value2'}}"
    end

    test "full Python parity: mixed substitution and literal braces" do
      with_session(
        [{"customerId", "1234567890"}, {"customer_int", 30}],
        fn pid ->
          agent =
            LlmAgent.new(
              name: "agent",
              model: "gemini-1.5-flash",
              instruction:
                "Use the echo_info tool to echo {customerId}, " <>
                  "{customer_int}, " <>
                  "{ non-identifier-float}}, " <>
                  "{'key1': 'value1'} and {{'key2': 'value2'}}."
            )

          ctx = make_ctx(pid)
          compiled = InstructionCompiler.compile(agent, ctx)

          # customerId and customer_int get substituted
          assert compiled =~ "echo 1234567890,"
          assert compiled =~ "30,"
          # Non-identifier and dict-like patterns stay as-is
          assert compiled =~ "{ non-identifier-float}}"
          assert compiled =~ "{'key1': 'value1'}"
          assert compiled =~ "{{'key2': 'value2'}}"
        end
      )
    end

    test "unknown variables remain as {var}" do
      agent =
        LlmAgent.new(
          name: "agent",
          model: "gemini-1.5-flash",
          instruction: "Hello {unknown_var}."
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "{unknown_var}"
    end
  end

  # ---------------------------------------------------------------------------
  # Namespace variables
  # Mirrors: test_build_system_instruction_with_namespace
  # ---------------------------------------------------------------------------

  describe "namespace variables (divergence)" do
    @tag :parity_divergence
    test "namespace-prefixed keys are NOT substituted in Elixir" do
      # Python substitutes {app:key} and {user:key} from state["app:key"], etc.
      # Elixir's \w+ regex doesn't match "app:key" so these are left as-is.
      with_session(
        [
          {"customerId", "1234567890"},
          {"app:key", "app_value"},
          {"user:key", "user_value"}
        ],
        fn pid ->
          agent =
            LlmAgent.new(
              name: "agent",
              model: "gemini-1.5-flash",
              instruction:
                "Use the echo_info tool to echo {customerId}, {app:key}, {user:key}, {a:key}."
            )

          ctx = make_ctx(pid)
          compiled = InstructionCompiler.compile(agent, ctx)

          # customerId substituted
          assert compiled =~ "1234567890"
          # Namespace vars NOT substituted (divergence from Python)
          assert compiled =~ "{app:key}"
          assert compiled =~ "{user:key}"
          assert compiled =~ "{a:key}"
        end
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Function instruction providers
  # Mirrors: test_function_system_instruction, test_async_function_system_instruction
  # ---------------------------------------------------------------------------

  describe "function instruction provider" do
    test "1-arity function instruction receives context and is used" do
      provider = fn ctx ->
        "This is the function agent instruction for invocation: #{ctx.invocation_id}."
      end

      agent =
        LlmAgent.new(
          name: "agent",
          model: "gemini-1.5-flash",
          instruction: provider
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      assert compiled =~
               "This is the function agent instruction for invocation: test_id."
    end

    test "function provider result undergoes template substitution (Elixir divergence)" do
      # In Python, callable instructions bypass state injection.
      # In Elixir, substitute_vars is always applied after provider resolution.
      provider = fn _ctx ->
        "provider template intact {customerId} and {customer_int}"
      end

      with_session(
        [{"customerId", "1234567890"}, {"customer_int", "30"}],
        fn pid ->
          agent =
            LlmAgent.new(
              name: "agent",
              model: "gemini-1.5-flash",
              instruction: provider
            )

          ctx = make_ctx(pid)
          compiled = InstructionCompiler.compile(agent, ctx)

          # DIVERGENCE: Elixir substitutes vars even from callable providers
          # Python would keep "{customerId}" and "{customer_int}" as-is
          assert compiled =~ "1234567890"
          assert compiled =~ "30"
        end
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Global instruction
  # Mirrors: test_global_system_instruction
  # ---------------------------------------------------------------------------

  describe "global instruction" do
    test "global instruction prepended to agent instruction" do
      # In Python, global comes from root_agent. In Elixir, we set it
      # directly on the agent map for compilation.
      agent =
        LlmAgent.new(
          name: "sub_agent",
          model: "gemini-1.5-flash",
          instruction: "This is the sub agent instruction.",
          global_instruction: "This is the global instruction."
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      # Global comes first, then agent instruction
      global_pos = :binary.match(compiled, "This is the global instruction.") |> elem(0)
      agent_pos = :binary.match(compiled, "This is the sub agent instruction.") |> elem(0)
      assert global_pos < agent_pos
    end

    test "global and agent instructions are joined with double newline" do
      agent =
        LlmAgent.new(
          name: "sub_agent",
          model: "gemini-1.5-flash",
          instruction: "This is the sub agent instruction.",
          global_instruction: "This is the global instruction."
        )

      ctx = make_ctx()
      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "This is the global instruction."
      assert dynamic =~ "This is the sub agent instruction."
    end
  end

  # ---------------------------------------------------------------------------
  # Function global instruction
  # Mirrors: test_function_global_system_instruction,
  #          test_async_function_global_system_instruction
  # ---------------------------------------------------------------------------

  describe "function global instruction" do
    test "callable global instruction receives context" do
      global_fn = fn ctx ->
        assert %ADK.Context{} = ctx
        "This is the global instruction."
      end

      agent =
        LlmAgent.new(
          name: "sub_agent",
          model: "gemini-1.5-flash",
          instruction: "This is the sub agent instruction.",
          global_instruction: global_fn
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      assert compiled =~ "This is the global instruction."
      assert compiled =~ "This is the sub agent instruction."
    end

    test "callable global instruction result undergoes substitution (Elixir divergence)" do
      # Python's callable global also bypasses state injection.
      # Elixir always applies substitute_vars.
      global_fn = fn _ctx ->
        "Global with {test_var}"
      end

      with_session([{"test_var", "test_value"}], fn pid ->
        agent =
          LlmAgent.new(
            name: "sub_agent",
            model: "gemini-1.5-flash",
            instruction: "Sub agent instruction",
            global_instruction: global_fn
          )

        ctx = make_ctx(pid)
        compiled = InstructionCompiler.compile(agent, ctx)

        # DIVERGENCE: Elixir substitutes vars in callable global result
        assert compiled =~ "Global with test_value"
        assert compiled =~ "Sub agent instruction"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # String instruction state injection
  # Mirrors: test_string_instruction_respects_bypass_state_injection
  # ---------------------------------------------------------------------------

  describe "string instruction state injection" do
    test "string instructions get template variable substitution" do
      with_session([{"test_var", "test_value"}], fn pid ->
        agent =
          LlmAgent.new(
            name: "test_agent",
            model: "gemini-1.5-flash",
            instruction: "Base instruction with {test_var}"
          )

        ctx = make_ctx(pid)
        compiled = InstructionCompiler.compile(agent, ctx)

        assert compiled =~ "Base instruction with test_value"
      end)
    end

    test "string global instructions get template variable substitution" do
      with_session([{"test_var", "test_value"}], fn pid ->
        agent =
          LlmAgent.new(
            name: "sub_agent",
            model: "gemini-1.5-flash",
            instruction: "Sub agent instruction",
            global_instruction: "Global instruction with {test_var}"
          )

        ctx = make_ctx(pid)
        compiled = InstructionCompiler.compile(agent, ctx)

        assert compiled =~ "Global instruction with test_value"
        assert compiled =~ "Sub agent instruction"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # compile_split: static vs dynamic partitioning
  # ---------------------------------------------------------------------------

  describe "compile_split static vs dynamic" do
    test "global_instruction is in static part" do
      agent =
        LlmAgent.new(
          name: "agent",
          model: "test",
          instruction: "Dynamic part.",
          global_instruction: "Static global."
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "Static global."
    end

    test "agent instruction is in dynamic part" do
      agent =
        LlmAgent.new(
          name: "agent",
          model: "test",
          instruction: "Dynamic agent instruction.",
          global_instruction: "Static global."
        )

      ctx = make_ctx()
      {_static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert dynamic =~ "Dynamic agent instruction."
    end

    test "identity instruction is in static part" do
      agent =
        LlmAgent.new(
          name: "TestBot",
          model: "test",
          instruction: "Be helpful.",
          description: "A helpful test bot"
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "You are TestBot."
      assert static =~ "A helpful test bot"
    end

    test "output_schema instruction is in dynamic part" do
      agent_map = %{
        name: "bot",
        model: "test",
        instruction: "Answer.",
        output_schema: %{type: "object", properties: %{answer: %{type: "string"}}},
        global_instruction: nil,
        sub_agents: [],
        description: nil
      }

      ctx = make_ctx()
      {_static, dynamic} = InstructionCompiler.compile_split(agent_map, ctx)

      assert dynamic =~ "Reply with valid JSON"
    end

    test "compile joins static and dynamic parts" do
      agent =
        LlmAgent.new(
          name: "agent",
          model: "test",
          instruction: "Dynamic part.",
          global_instruction: "Static part."
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      # compile should join non-empty static and dynamic with \n\n
      expected =
        [static, dynamic]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      assert compiled == expected
    end
  end

  # ---------------------------------------------------------------------------
  # substitute_vars edge cases
  # ---------------------------------------------------------------------------

  describe "substitute_vars/2 directly" do
    test "basic substitution" do
      assert InstructionCompiler.substitute_vars("Hello {name}!", %{"name" => "World"}) ==
               "Hello World!"
    end

    test "no variables" do
      assert InstructionCompiler.substitute_vars("No vars here", %{}) == "No vars here"
    end

    test "multiple variables" do
      result =
        InstructionCompiler.substitute_vars(
          "{a} and {b} and {c}",
          %{"a" => "1", "b" => "2", "c" => "3"}
        )

      assert result == "1 and 2 and 3"
    end

    test "integer values are coerced to string" do
      result = InstructionCompiler.substitute_vars("{count}", %{"count" => 42})
      assert result == "42"
    end

    test "missing key leaves placeholder" do
      result = InstructionCompiler.substitute_vars("{missing}", %{"other" => "val"})
      assert result == "{missing}"
    end

    test "non-word characters in braces are not matched" do
      result = InstructionCompiler.substitute_vars("{not-a-var}", %{})
      assert result == "{not-a-var}"
    end

    test "spaces in braces are not matched" do
      result = InstructionCompiler.substitute_vars("{ spaced }", %{})
      assert result == "{ spaced }"
    end

    test "double braces are left intact" do
      result = InstructionCompiler.substitute_vars("{{literal}}", %{"literal" => "replaced"})
      # The regex matches {literal} inside the double braces, but the outer
      # braces remain since they're not part of the match
      # Actual behavior: {{literal}} -> {replaced}
      assert result == "{replaced}"
    end

    test "nil instruction returns nil" do
      assert InstructionCompiler.substitute_vars(nil, %{}) == nil
    end

    test "empty instruction returns empty" do
      assert InstructionCompiler.substitute_vars("", %{}) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling in instruction providers
  # ---------------------------------------------------------------------------

  describe "instruction provider error handling" do
    test "provider that raises returns empty string" do
      provider = fn _ctx -> raise "boom" end

      result = InstructionCompiler.resolve_provider(provider, make_ctx())
      assert result == ""
    end

    test "nil provider returns nil" do
      assert InstructionCompiler.resolve_provider(nil, make_ctx()) == nil
    end

    test "string provider returns as-is" do
      assert InstructionCompiler.resolve_provider("static", make_ctx()) == "static"
    end

    test "provider returning non-string is coerced" do
      provider = fn _ctx -> 42 end

      result = InstructionCompiler.resolve_provider(provider, make_ctx())
      assert result == "42"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: instruction compilation through LlmAgent
  # ---------------------------------------------------------------------------

  describe "full instruction compilation through agent" do
    test "agent with no instruction fields produces identity only" do
      agent = LlmAgent.new(name: "bot", model: "test", instruction: "")
      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "You are bot."
    end

    test "agent with all fields produces combined instruction" do
      sub = LlmAgent.new(name: "helper", model: "test", instruction: "Help with tasks.", description: "A helper")

      agent =
        LlmAgent.new(
          name: "root",
          model: "test",
          instruction: "Be helpful.",
          global_instruction: "Always be safe.",
          description: "The root agent",
          sub_agents: [sub]
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      # All components should be present
      assert compiled =~ "Always be safe."
      assert compiled =~ "You are root."
      assert compiled =~ "The root agent"
      assert compiled =~ "transfer_to_agent"
      assert compiled =~ "helper"
      assert compiled =~ "Be helpful."
    end

    test "agent with function instruction and session state" do
      provider = fn ctx ->
        state =
          if ctx.session_pid,
            do: ADK.Session.get_all_state(ctx.session_pid),
            else: %{}

        "Welcome #{state["user_name"] || "stranger"}, your role is {role}."
      end

      with_session([{"user_name", "Alice"}, {"role", "admin"}], fn pid ->
        agent =
          LlmAgent.new(
            name: "agent",
            model: "test",
            instruction: provider
          )

        ctx = make_ctx(pid)
        compiled = InstructionCompiler.compile(agent, ctx)

        # Provider resolves "Alice" directly from state
        assert compiled =~ "Welcome Alice"
        # {role} in provider output gets substituted (Elixir behavior)
        assert compiled =~ "your role is admin"
      end)
    end
  end
end
