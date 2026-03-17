defmodule ADK.Agent.LlmAgentFieldsTest do
  @moduledoc """
  Parity tests for LlmAgent fields, mirroring Python ADK's
  `tests/unittests/agents/test_llm_agent_fields.py`.

  Covers: instruction providers, global instructions, template variable
  substitution, agent struct fields, tool resolution, and output schema
  instruction generation.

  Skipped (Python-only): model resolution (Claude/LiteLLM), canonical_model,
  Pydantic validation, bypass_multi_tools_limit, VertexAiSearchTool,
  async instruction providers.
  """
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.InstructionCompiler
  alias ADK.Tool.FunctionTool
  alias ADK.Tool.GoogleSearch

  # MFA instruction provider helpers (must be in a compiled module)
  defmodule Providers do
    def static_provider(_ctx), do: "MFA static instruction"
    def provider_with_args(_ctx, arg), do: "MFA with args: #{arg}"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_ctx(session_pid \\ nil) do
    %ADK.Context{
      invocation_id: "inv-fields-test",
      session_pid: session_pid,
      agent: nil,
      user_content: %{text: "test"}
    }
  end

  defp with_session(state, fun) do
    {:ok, pid} =
      ADK.Session.start_link(
        app_name: "fields_test",
        user_id: "u1",
        session_id: "s-#{System.unique_integer([:positive])}"
      )

    for {k, v} <- state, do: ADK.Session.put_state(pid, k, v)
    result = fun.(pid)
    GenServer.stop(pid)
    result
  end

  # ---------------------------------------------------------------------------
  # 1. Instruction tests
  # ---------------------------------------------------------------------------
  describe "instruction — string" do
    test "static string instruction compiles as-is" do
      agent = LlmAgent.new(name: "bot", model: "test", instruction: "Be helpful.")
      ctx = make_ctx()

      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "Be helpful."
    end
  end

  describe "instruction — function provider" do
    test "1-arity function instruction receives context" do
      provider = fn ctx ->
        assert %ADK.Context{} = ctx
        "Dynamic instruction"
      end

      agent = LlmAgent.new(name: "bot", model: "test", instruction: provider)
      ctx = make_ctx()

      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "Dynamic instruction"
    end

    test "function provider can access session state" do
      provider = fn ctx ->
        state =
          if ctx.session_pid,
            do: ADK.Session.get_all_state(ctx.session_pid),
            else: %{}

        "User preference: #{state["color"] || "none"}"
      end

      with_session(%{"color" => "blue"}, fn pid ->
        agent = LlmAgent.new(name: "bot", model: "test", instruction: provider)
        ctx = make_ctx(pid)

        compiled = InstructionCompiler.compile(agent, ctx)
        assert compiled =~ "User preference: blue"
      end)
    end
  end

  describe "instruction — template variable interpolation" do
    test "substitutes {variable} from session state" do
      with_session(%{"name" => "Alice", "role" => "admin"}, fn pid ->
        agent =
          LlmAgent.new(
            name: "bot",
            model: "test",
            instruction: "Hello {name}, you are {role}."
          )

        ctx = make_ctx(pid)
        compiled = InstructionCompiler.compile(agent, ctx)
        assert compiled =~ "Hello Alice, you are admin."
      end)
    end

    test "leaves unknown variables unchanged" do
      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Hello {unknown_var}."
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "Hello {unknown_var}."
    end
  end

  describe "global_instruction" do
    test "static string global instruction is included" do
      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Local.",
          global_instruction: "Always be safe."
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "Always be safe."
      assert compiled =~ "Local."
    end

    test "function global instruction receives context" do
      global_fn = fn ctx ->
        assert %ADK.Context{} = ctx
        "Global from function"
      end

      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          global_instruction: global_fn
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "Global from function"
    end

    test "global instruction supports template vars" do
      with_session(%{"app" => "MyApp"}, fn pid ->
        agent =
          LlmAgent.new(
            name: "bot",
            model: "test",
            global_instruction: "Welcome to {app}."
          )

        ctx = make_ctx(pid)
        compiled = InstructionCompiler.compile(agent, ctx)
        assert compiled =~ "Welcome to MyApp."
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Agent struct fields
  # ---------------------------------------------------------------------------
  describe "agent struct fields" do
    test "name and description are accessible" do
      agent = LlmAgent.new(name: "researcher", model: "test", description: "Finds answers")
      assert agent.name == "researcher"
      assert agent.description == "Finds answers"
    end

    test "protocol accessors match struct fields" do
      agent = LlmAgent.new(name: "helper", model: "test", description: "Helpful bot")
      assert ADK.Agent.name(agent) == "helper"
      assert ADK.Agent.description(agent) == "Helpful bot"
      assert ADK.Agent.sub_agents(agent) == []
    end

    test "sub_agents default to empty list" do
      agent = LlmAgent.new(name: "bot", model: "test")
      assert agent.sub_agents == []
    end

    test "tools default to empty list" do
      agent = LlmAgent.new(name: "bot", model: "test")
      assert agent.tools == []
    end

    test "agent with sub_agents and tools doesn't crash" do
      tool =
        FunctionTool.new(:greet,
          description: "Greet",
          func: fn _ctx, _args -> {:ok, "hi"} end,
          parameters: %{}
        )

      sub = LlmAgent.new(name: "sub", model: "test")

      agent =
        LlmAgent.new(
          name: "parent",
          model: "test",
          tools: [tool],
          sub_agents: [sub]
        )

      assert length(agent.tools) == 1
      assert length(agent.sub_agents) == 1
      assert hd(agent.sub_agents).name == "sub"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Tool resolution
  # ---------------------------------------------------------------------------
  describe "tool resolution" do
    test "FunctionTool wraps function with metadata" do
      tool =
        FunctionTool.new(:calc,
          description: "Calculate",
          func: fn _ctx, %{"expr" => e} -> {:ok, e} end,
          parameters: %{type: "object", properties: %{expr: %{type: "string"}}}
        )

      assert tool.name == "calc"
      assert tool.description == "Calculate"
      assert is_function(tool.func) or is_tuple(tool.func)
      assert tool.parameters.type == "object"
    end

    test "multiple tools resolve correctly on agent" do
      t1 =
        FunctionTool.new(:tool_a,
          description: "A",
          func: fn _, _ -> {:ok, "a"} end,
          parameters: %{}
        )

      t2 =
        FunctionTool.new(:tool_b,
          description: "B",
          func: fn _, _ -> {:ok, "b"} end,
          parameters: %{}
        )

      agent = LlmAgent.new(name: "multi", model: "test", tools: [t1, t2])
      assert length(agent.tools) == 2
      names = Enum.map(agent.tools, & &1.name)
      assert "tool_a" in names
      assert "tool_b" in names
    end

    test "GoogleSearch tool coexists with function tools" do
      gs = GoogleSearch.new()

      ft =
        FunctionTool.new(:lookup,
          description: "Look up",
          func: fn _, _ -> {:ok, "found"} end,
          parameters: %{}
        )

      agent = LlmAgent.new(name: "hybrid", model: "test", tools: [gs, ft])
      assert length(agent.tools) == 2
      assert %GoogleSearch{} = Enum.find(agent.tools, &is_struct(&1, GoogleSearch))
      assert %FunctionTool{} = Enum.find(agent.tools, &is_struct(&1, FunctionTool))
    end

    test "GoogleSearch has correct builtin marker" do
      gs = GoogleSearch.new()
      assert gs.__builtin__ == :google_search
      assert gs.name == "google_search"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Output schema & generate_content_config
  # ---------------------------------------------------------------------------
  describe "output schema" do
    test "output_schema generates JSON instruction via InstructionCompiler" do
      # LlmAgent struct doesn't have output_schema field, but
      # InstructionCompiler uses Map.get so we can test via a plain map
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
      compiled = InstructionCompiler.compile(agent_map, ctx)
      assert compiled =~ "Reply with valid JSON matching this schema"
      assert compiled =~ "answer"
    end

    test "nil output_schema produces no schema instruction" do
      agent = LlmAgent.new(name: "bot", model: "test", instruction: "Plain.")
      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      refute compiled =~ "Reply with valid JSON"
    end
  end

  describe "generate_content_config passthrough" do
    test "agent struct accepts arbitrary keys via new/1" do
      # LlmAgent.new uses struct/2 which ignores unknown keys,
      # but the known fields pass through correctly
      agent =
        LlmAgent.new(
          name: "configured",
          model: "gemini-2.0-flash",
          instruction: "Be precise.",
          description: "A configured agent"
        )

      assert agent.name == "configured"
      assert agent.model == "gemini-2.0-flash"
      assert agent.instruction == "Be precise."
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Agent tree utilities
  # ---------------------------------------------------------------------------
  describe "agent tree" do
    test "get_available_agent_names collects all names" do
      child1 = LlmAgent.new(name: "child1", model: "test")
      child2 = LlmAgent.new(name: "child2", model: "test")

      root =
        LlmAgent.new(
          name: "root",
          model: "test",
          sub_agents: [child1, child2]
        )

      names = LlmAgent.get_available_agent_names(root)
      assert "root" in names
      assert "child1" in names
      assert "child2" in names
      assert length(names) == 3
    end

    test "get_agent_to_run finds nested agent" do
      grandchild = LlmAgent.new(name: "gc", model: "test")
      child = LlmAgent.new(name: "mid", model: "test", sub_agents: [grandchild])
      root = LlmAgent.new(name: "root", model: "test", sub_agents: [child])

      assert {:ok, found} = LlmAgent.get_agent_to_run(root, "gc")
      assert found.name == "gc"
    end

    test "get_agent_to_run raises for unknown agent" do
      root = LlmAgent.new(name: "root", model: "test")

      assert_raise ArgumentError, ~r/not found/, fn ->
        LlmAgent.get_agent_to_run(root, "nonexistent")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 6. InstructionCompiler compile_split (static vs dynamic)
  # ---------------------------------------------------------------------------
  describe "compile_split" do
    test "global_instruction is static, agent instruction is dynamic" do
      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "Dynamic part.",
          global_instruction: "Static part."
        )

      ctx = make_ctx()
      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      assert static =~ "Static part."
      assert dynamic =~ "Dynamic part."
    end

    test "transfer instruction appears in static part" do
      sub = LlmAgent.new(name: "helper", model: "test", description: "Helps with things")

      agent =
        LlmAgent.new(
          name: "root",
          model: "test",
          sub_agents: [sub]
        )

      ctx = make_ctx()
      {static, _dynamic} = InstructionCompiler.compile_split(agent, ctx)
      assert static =~ "helper"
      assert static =~ "transfer_to_agent"
    end
  end

  # ---------------------------------------------------------------------------
  # 7. MFA instruction providers
  # ---------------------------------------------------------------------------
  describe "MFA instruction providers" do
    test "{module, function} tuple as instruction" do
      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: {__MODULE__.Providers, :static_provider}
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "MFA static instruction"
    end

    test "{module, function, args} tuple as instruction" do
      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: {__MODULE__.Providers, :provider_with_args, ["extra"]}
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)
      assert compiled =~ "MFA with args: extra"
    end
  end
end
