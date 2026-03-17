defmodule ADK.AgentConfigTest do
  @moduledoc """
  Parity tests for Python's `test_agent_config.py`.

  Covers:
  - agent_class discriminator (default → LlmAgent, explicit types)
  - Loading from YAML files via from_config/1
  - Sub-agents loaded via config_path references
  - Model config with custom args (LiteLlm-style)
  - Legacy model mapping
  - Relative path resolution for sub-agents
  """
  use ExUnit.Case, async: true

  alias ADK.Agent.{LlmAgent, LoopAgent, ParallelAgent, SequentialAgent}
  alias ADK.AgentConfig

  # ── Discriminator defaults to LlmAgent ──

  describe "discriminator defaults" do
    test "no agent_class → LlmAgent" do
      yaml = """
      name: search_agent
      model: gemini-2.0-flash
      description: a sample description
      instruction: a fake instruction
      """

      {:ok, agent} = AgentConfig.from_yaml(yaml)
      assert %LlmAgent{} = agent
      assert agent.name == "search_agent"
      assert agent.model == "gemini-2.0-flash"

      # Also verify parse gives default agent_class
      {:ok, config} = AgentConfig.parse(yaml)
      assert config["agent_class"] == "LlmAgent"
    end
  end

  # ── Explicit LlmAgent discriminator ──

  describe "LlmAgent discriminator" do
    for class <- ["LlmAgent", "google.adk.agents.LlmAgent", "google.adk.agents.llm_agent.LlmAgent"] do
      @class class
      test "agent_class #{@class} → LlmAgent" do
        yaml = """
        agent_class: #{@class}
        name: search_agent
        model: gemini-2.0-flash
        description: a sample description
        instruction: a fake instruction
        """

        {:ok, agent} = AgentConfig.from_yaml(yaml)
        assert %LlmAgent{} = agent
        assert agent.name == "search_agent"
      end
    end
  end

  # ── LoopAgent discriminator ──

  describe "LoopAgent discriminator" do
    for class <- ["LoopAgent", "google.adk.agents.LoopAgent", "google.adk.agents.loop_agent.LoopAgent"] do
      @class class
      test "agent_class #{@class} → LoopAgent" do
        yaml = """
        agent_class: #{@class}
        name: CodePipelineAgent
        description: Executes a sequence of code writing, reviewing, and refactoring.
        sub_agents: []
        """

        {:ok, agent} = AgentConfig.from_yaml(yaml)
        assert %LoopAgent{} = agent
        assert agent.name == "CodePipelineAgent"
      end
    end
  end

  # ── ParallelAgent discriminator ──

  describe "ParallelAgent discriminator" do
    for class <- ["ParallelAgent", "google.adk.agents.ParallelAgent", "google.adk.agents.parallel_agent.ParallelAgent"] do
      @class class
      test "agent_class #{@class} → ParallelAgent" do
        yaml = """
        agent_class: #{@class}
        name: CodePipelineAgent
        description: Executes a sequence of code writing, reviewing, and refactoring.
        sub_agents: []
        """

        {:ok, agent} = AgentConfig.from_yaml(yaml)
        assert %ParallelAgent{} = agent
        assert agent.name == "CodePipelineAgent"
      end
    end
  end

  # ── SequentialAgent discriminator ──

  describe "SequentialAgent discriminator" do
    for class <- ["SequentialAgent", "google.adk.agents.SequentialAgent", "google.adk.agents.sequential_agent.SequentialAgent"] do
      @class class
      test "agent_class #{@class} → SequentialAgent" do
        yaml = """
        agent_class: #{@class}
        name: CodePipelineAgent
        description: Executes a sequence of code writing, reviewing, and refactoring.
        sub_agents: []
        """

        {:ok, agent} = AgentConfig.from_yaml(yaml)
        assert %SequentialAgent{} = agent
        assert agent.name == "CodePipelineAgent"
      end
    end
  end

  # ── Composite agents with sub-agents loaded via config_path ──

  describe "composite agents with config_path sub-agents" do
    for {class, mod} <- [
          {"LoopAgent", LoopAgent},
          {"ParallelAgent", ParallelAgent},
          {"SequentialAgent", SequentialAgent}
        ] do
      @class class
      @mod mod
      test "#{class} loads sub-agents from config_path" do
        tmp_dir = make_tmp_dir()
        sub_dir = Path.join(tmp_dir, "sub_agents")
        File.mkdir_p!(sub_dir)

        for i <- 1..2 do
          File.write!(Path.join(sub_dir, "sub_agent#{i}.yaml"), """
          name: sub_agent_#{i}
          model: gemini-2.0-flash
          description: a sub agent
          instruction: sub agent instruction
          """)
        end

        config_path = Path.join(tmp_dir, "test_config.yaml")
        File.write!(config_path, """
        agent_class: #{@class}
        name: main_agent
        description: main agent with sub agents
        sub_agents:
          - config_path: sub_agents/sub_agent1.yaml
          - config_path: sub_agents/sub_agent2.yaml
        """)

        {:ok, agent} = AgentConfig.from_config(config_path)
        assert agent.__struct__ == @mod
        assert length(agent.sub_agents) == 2

        [s1, s2] = agent.sub_agents
        assert %LlmAgent{name: "sub_agent_1"} = s1
        assert %LlmAgent{name: "sub_agent_2"} = s2
      end
    end

    test "LlmAgent loads sub-agents from config_path" do
      tmp_dir = make_tmp_dir()
      sub_dir = Path.join(tmp_dir, "sub_agents")
      File.mkdir_p!(sub_dir)

      for i <- 1..2 do
        File.write!(Path.join(sub_dir, "sub_agent#{i}.yaml"), """
        name: sub_agent_#{i}
        model: gemini-2.0-flash
        description: a sub agent
        instruction: sub agent instruction
        """)
      end

      config_path = Path.join(tmp_dir, "test_config.yaml")
      File.write!(config_path, """
      agent_class: LlmAgent
      name: main_agent
      model: gemini-2.0-flash
      description: main agent with sub agents
      instruction: main agent instruction
      sub_agents:
        - config_path: sub_agents/sub_agent1.yaml
        - config_path: sub_agents/sub_agent2.yaml
      """)

      {:ok, agent} = AgentConfig.from_config(config_path)
      assert %LlmAgent{} = agent
      assert length(agent.sub_agents) == 2
    end
  end

  # ── Model config with custom args (LiteLlm-style) ──

  describe "model_code with custom args" do
    test "model_code produces structured model config" do
      tmp_dir = make_tmp_dir()
      config_path = Path.join(tmp_dir, "litellm_agent.yaml")

      File.write!(config_path, """
      name: managed_api_agent
      description: Agent using LiteLLM managed endpoint
      instruction: Respond concisely.
      model_code:
        name: google.adk.models.lite_llm.LiteLlm
        args:
          - name: model
            value: kimi/k2
          - name: api_base
            value: https://proxy.litellm.ai/v1
      """)

      {:ok, agent} = AgentConfig.from_config(config_path)
      assert %LlmAgent{} = agent

      # model is a map with structured info
      assert is_map(agent.model)
      assert agent.model.name == "google.adk.models.lite_llm.LiteLlm"
      assert agent.model.model == "kimi/k2"
      assert agent.model.args["api_base"] == "https://proxy.litellm.ai/v1"
    end
  end

  # ── Legacy model mapping (model field as map) ──

  describe "legacy model mapping" do
    test "model as map with name and args is still supported" do
      tmp_dir = make_tmp_dir()
      config_path = Path.join(tmp_dir, "legacy_agent.yaml")

      File.write!(config_path, """
      name: managed_api_agent
      description: Agent using LiteLLM managed endpoint
      instruction: Respond concisely.
      model:
        name: google.adk.models.lite_llm.LiteLlm
        args:
          - name: model
            value: kimi/k2
      """)

      {:ok, agent} = AgentConfig.from_config(config_path)
      assert %LlmAgent{} = agent
      assert is_map(agent.model)
      assert agent.model.model == "kimi/k2"
    end
  end

  # ── Custom / unknown agent_class falls through gracefully ──

  describe "custom agent types" do
    test "unknown agent_class returns error" do
      yaml = """
      agent_class: mylib.agents.MyCustomAgent
      name: CodePipelineAgent
      description: Executes stuff.
      other_field: other value
      """

      assert {:error, "Unknown agent_class: mylib.agents.MyCustomAgent"} =
               AgentConfig.from_yaml(yaml)
    end

    test "parse returns the raw agent_class for custom types" do
      yaml = """
      agent_class: mylib.agents.MyCustomAgent
      name: CodePipelineAgent
      description: Executes stuff.
      """

      {:ok, config} = AgentConfig.parse(yaml)
      assert config["agent_class"] == "mylib.agents.MyCustomAgent"
    end
  end

  # ── Relative path resolution ──

  describe "relative path resolution for sub-agents" do
    test "sub-agent config_path resolved relative to parent config file" do
      tmp_dir = make_tmp_dir()
      child_dir = Path.join(tmp_dir, "sub_agents")
      File.mkdir_p!(child_dir)

      File.write!(Path.join(child_dir, "child.yaml"), """
      agent_class: LlmAgent
      name: child_agent
      model: gemini-2.0-flash
      instruction: I am a child agent
      """)

      config_path = Path.join(tmp_dir, "main.yaml")
      File.write!(config_path, """
      agent_class: LlmAgent
      name: main_agent
      model: gemini-2.0-flash
      instruction: I am the main agent
      sub_agents:
        - config_path: sub_agents/child.yaml
      """)

      {:ok, agent} = AgentConfig.from_config(config_path)
      assert %LlmAgent{name: "main_agent"} = agent
      assert [%LlmAgent{name: "child_agent"}] = agent.sub_agents
    end

    test "deeply nested config_path resolution" do
      tmp_dir = make_tmp_dir()
      nested_dir = Path.join([tmp_dir, "level1", "level2"])
      File.mkdir_p!(nested_dir)

      child_dir = Path.join(nested_dir, "sub")
      File.mkdir_p!(child_dir)

      File.write!(Path.join(child_dir, "nested_child.yaml"), """
      agent_class: LlmAgent
      name: nested_child
      model: gemini-2.0-flash
      instruction: I am nested
      """)

      config_path = Path.join(nested_dir, "nested_main.yaml")
      File.write!(config_path, """
      agent_class: LlmAgent
      name: main_agent
      model: gemini-2.0-flash
      instruction: I am the main agent
      sub_agents:
        - config_path: sub/nested_child.yaml
      """)

      {:ok, agent} = AgentConfig.from_config(config_path)
      assert %LlmAgent{name: "main_agent"} = agent
      assert [%LlmAgent{name: "nested_child"}] = agent.sub_agents
    end
  end

  # ── Windows-style path handling (N/A in Elixir) ──

  describe "Windows-style paths" do
    @tag :skip
    test "Windows backslash paths are not applicable in Elixir/BEAM" do
      # Python test uses ntpath mocking for Windows-style paths.
      # BEAM always uses POSIX paths, so this test is skipped.
    end
  end

  # ── from_config!/1 raises on bad file ──

  describe "error handling" do
    test "from_config! raises on missing file" do
      assert_raise ArgumentError, fn ->
        AgentConfig.from_config!("/nonexistent/path/agent.yaml")
      end
    end

    test "from_yaml! raises on invalid YAML" do
      assert_raise ArgumentError, fn ->
        AgentConfig.from_yaml!("{{invalid yaml")
      end
    end
  end

  # ── Helpers ──

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "adk_config_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
