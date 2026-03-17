defmodule ADK.Integration.ContextVariableTest do
  @moduledoc """
  Parity test for Python ADK's tests/integration/test_context_variable.py

  NOTE: The Python source test is currently skipped at module level
  (`pytest.skip(allow_module_level=True)`). These tests document and verify
  Elixir ADK's equivalent behavior for context variable handling.

  ## Key behavioral difference

  - **Python ADK** raises `KeyError` when a context variable referenced in
    an instruction is absent from session state.
  - **Elixir ADK** keeps the `{variable}` placeholder intact (no error raised).
    This is intentional — Elixir opts for resilience over strict failure.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ADK.Context
  alias ADK.InstructionCompiler
  alias ADK.ToolContext

  # ─────────────────────────────────────────────────
  # Mirrors: test_context_variable_missing
  # ─────────────────────────────────────────────────

  describe "context variable missing — substitute_vars behaviour" do
    test "missing context variable keeps placeholder intact (Python raises KeyError)" do
      instruction = "Use the echo_info tool to echo {customerId}. Ask for it if you need to."

      result = InstructionCompiler.substitute_vars(instruction, %{})

      # Elixir does NOT raise — it preserves the placeholder
      assert result =~ "{customerId}"
      assert result == instruction
    end

    test "multiple missing context variables are all preserved as-is" do
      instruction = "Echo {customerId}, {customerInt}, {customerFloat}, {customerJson}."

      result = InstructionCompiler.substitute_vars(instruction, %{})

      assert result =~ "{customerId}"
      assert result =~ "{customerInt}"
      assert result =~ "{customerFloat}"
      assert result =~ "{customerJson}"
    end

    test "present context variable is correctly substituted" do
      instruction = "Use the echo_info tool to echo {customerId}. Ask for it if you need to."

      result = InstructionCompiler.substitute_vars(instruction, %{"customerId" => "CUST-42"})

      assert result =~ "CUST-42"
      refute result =~ "{customerId}"
    end

    test "partial substitution — present vars replaced, absent vars preserved" do
      instruction = "Customer: {customerId}, Int: {customerInt}"

      result = InstructionCompiler.substitute_vars(instruction, %{"customerId" => "CUST-99"})

      assert result =~ "CUST-99"
      assert result =~ "{customerInt}"
    end

    test "atom-keyed state values are also substituted" do
      instruction = "Hello {name}!"

      result = InstructionCompiler.substitute_vars(instruction, %{name: "World"})

      assert result == "Hello World!"
    end
  end

  # ─────────────────────────────────────────────────
  # Mirrors: test_context_variable_update
  # ─────────────────────────────────────────────────

  describe "context variable update via ToolContext.put_state/3" do
    setup do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "context_variable_test",
          user_id: "user1",
          session_id: "ctx-var-#{System.unique_integer([:positive])}",
          name: nil
        )

      ctx = %Context{
        invocation_id: "inv-ctx-var-1",
        session_pid: session_pid,
        agent: nil,
        callbacks: [],
        policies: []
      }

      tool_ctx = ToolContext.new(ctx, "call-update-fc", %{name: "update_fc"})

      on_exit(fn ->
        if Process.alive?(session_pid), do: GenServer.stop(session_pid)
      end)

      %{tool_ctx: tool_ctx, session_pid: session_pid}
    end

    test "update_fc equivalent: stores string, float, list[str], list[mixed] in session state",
         %{tool_ctx: tc} do
      # Mirrors Python fixture's update_fc("RRRR", 3.141529, ["apple", "banana"], [1, 3.14, "hello"])
      {:ok, tc} = ToolContext.put_state(tc, "data_one", "RRRR")
      {:ok, tc} = ToolContext.put_state(tc, "data_two", 3.141529)
      {:ok, tc} = ToolContext.put_state(tc, "data_three", ["apple", "banana"])
      {:ok, tc} = ToolContext.put_state(tc, "data_four", [1, 3.14, "hello"])

      assert ToolContext.get_state(tc, "data_one") == "RRRR"
      assert ToolContext.get_state(tc, "data_two") == 3.141529
      assert ToolContext.get_state(tc, "data_three") == ["apple", "banana"]
      assert ToolContext.get_state(tc, "data_four") == [1, 3.14, "hello"]
    end

    test "state_delta in EventActions tracks all updates", %{tool_ctx: tc} do
      {:ok, tc} = ToolContext.put_state(tc, "data_one", "RRRR")
      {:ok, tc} = ToolContext.put_state(tc, "data_two", 3.141529)

      actions = ToolContext.actions(tc)
      assert actions.state_delta["data_one"] == "RRRR"
      assert actions.state_delta["data_two"] == 3.141529
    end

    test "tool result string mirrors Python 'successfully' assertion", %{tool_ctx: tc} do
      # Python assertion: expected = "successfully"
      # Elixir equivalent — simulate the update_fc tool return value
      {:ok, tc} = ToolContext.put_state(tc, "data_one", "RRRR")

      result =
        if ToolContext.get_state(tc, "data_one") == "RRRR",
          do: "The function `update_fc` executed successfully",
          else: "error"

      assert result =~ "successfully"
    end

    test "state persists across separate ToolContext access on same session",
         %{session_pid: session_pid} do
      # First tool call
      ctx = %Context{invocation_id: "inv-A", session_pid: session_pid,
                     agent: nil, callbacks: [], policies: []}
      tc1 = ToolContext.new(ctx, "call-1", %{name: "update_fc"})
      {:ok, _tc1} = ToolContext.put_state(tc1, "customerId", "CUSTOMER-XYZ")

      # Second tool call (new ToolContext, same session)
      tc2 = ToolContext.new(ctx, "call-2", %{name: "echo_info"})
      assert ToolContext.get_state(tc2, "customerId") == "CUSTOMER-XYZ"
    end

    test "updated state variable is substituted in compiled instruction",
         %{tool_ctx: tc, session_pid: session_pid} do
      {:ok, _tc} = ToolContext.put_state(tc, "customerId", "CUST-777")

      agent = %{
        name: "context_variable_echo_agent",
        description: nil,
        instruction:
          "Use the echo_info tool to echo {customerId}, {customerInt}, " <>
            "{customerFloat}, and {customerJson}. Ask for it if you need to.",
        global_instruction: nil,
        output_schema: nil,
        sub_agents: []
      }

      ctx = %Context{
        invocation_id: "inv-compile",
        session_pid: session_pid,
        agent: nil,
        callbacks: [],
        policies: []
      }

      compiled = InstructionCompiler.compile(agent, ctx)

      # customerId was stored → substituted
      assert compiled =~ "CUST-777"
      refute compiled =~ "{customerId}"

      # Other variables were NOT stored → kept as placeholders
      assert compiled =~ "{customerInt}"
      assert compiled =~ "{customerFloat}"
      assert compiled =~ "{customerJson}"
    end

    test "missing state key returns nil from get_state/2", %{tool_ctx: tc} do
      assert ToolContext.get_state(tc, "customerId") == nil
    end

    test "missing state key returns default from get_state/3", %{tool_ctx: tc} do
      assert ToolContext.get_state(tc, "customerId", "unknown") == "unknown"
    end
  end

  # ─────────────────────────────────────────────────
  # Context variable with function instruction provider
  # (mirrors context_variable_with_function_instruction_agent fixture)
  # ─────────────────────────────────────────────────

  describe "function instruction provider with context variable support" do
    setup do
      {:ok, session_pid} =
        ADK.Session.start_link(
          app_name: "ctx_func_instr_test",
          user_id: "user1",
          session_id: "func-instr-#{System.unique_integer([:positive])}",
          name: nil
        )

      on_exit(fn ->
        if Process.alive?(session_pid), do: GenServer.stop(session_pid)
      end)

      %{session_pid: session_pid}
    end

    test "global_instruction provider receives invocation context", %{session_pid: session_pid} do
      # Mirrors build_global_instruction(invocation_context) fixture
      provider = fn ctx ->
        "This is the global agent instruction for invocation: #{ctx.invocation_id}."
      end

      agent = %{
        name: "root_agent",
        description: "The root agent.",
        instruction: nil,
        global_instruction: provider,
        output_schema: nil,
        sub_agents: []
      }

      ctx = %Context{
        invocation_id: "inv-test-42",
        session_pid: session_pid,
        agent: nil,
        callbacks: [],
        policies: []
      }

      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "inv-test-42"
    end

    test "static-string function instruction provider returns constant", %{session_pid: session_pid} do
      # Mirrors build_sub_agent_instruction(invocation_context) fixture
      provider = fn _ctx -> "This is the plain text sub agent instruction." end

      agent = %{
        name: "context_variable_with_function_instruction_agent",
        description: nil,
        instruction: provider,
        global_instruction: nil,
        output_schema: nil,
        sub_agents: []
      }

      ctx = %Context{
        invocation_id: "inv-any",
        session_pid: session_pid,
        agent: nil,
        callbacks: [],
        policies: []
      }

      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "plain text sub agent instruction"
    end

    test "function instruction result still supports {var} substitution after resolve",
         %{session_pid: session_pid} do
      # Provider returns a string with a template variable; it should still be substituted
      provider = fn _ctx -> "Welcome, {customerId}!" end

      agent = %{
        name: "dynamic_agent",
        description: nil,
        instruction: provider,
        global_instruction: nil,
        output_schema: nil,
        sub_agents: []
      }

      ADK.Session.put_state(session_pid, "customerId", "CUST-DYNAMIC")

      ctx = %Context{
        invocation_id: "inv-dyn",
        session_pid: session_pid,
        agent: nil,
        callbacks: [],
        policies: []
      }

      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "CUST-DYNAMIC"
      refute compiled =~ "{customerId}"
    end
  end
end
