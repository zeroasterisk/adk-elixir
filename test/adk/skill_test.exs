defmodule ADK.SkillTest do
  use ExUnit.Case, async: true

  alias ADK.Skill

  # --- Helpers ---

  defp tmp_dir(name) do
    dir = Path.join(System.tmp_dir!(), "adk_skill_test_#{name}_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_skill_md(dir, content) do
    File.write!(Path.join(dir, "SKILL.md"), content)
  end

  # --- from_dir/1 ---

  describe "from_dir/1" do
    test "loads a skill with full SKILL.md" do
      dir = tmp_dir("full")

      write_skill_md(dir, """
      # My Skill

      > A helpful skill for testing.

      ## Instructions

      Do something useful here.
      """)

      assert {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "My Skill"
      assert skill.description == "A helpful skill for testing."
      assert String.contains?(skill.instruction, "Do something useful here.")
      assert skill.dir == dir
      assert skill.tools == []
    end

    test "uses directory basename as name when no heading" do
      dir = tmp_dir("noheading")
      write_skill_md(dir, "Just some instruction text without a heading.")

      assert {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == Path.basename(dir)
      assert skill.description == nil
    end

    test "description is nil when no blockquote" do
      dir = tmp_dir("nodesc")
      write_skill_md(dir, "# Skill Without Desc\n\nSome instructions.")

      assert {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "Skill Without Desc"
      assert skill.description == nil
    end

    test "trims whitespace from name and description" do
      dir = tmp_dir("whitespace")
      write_skill_md(dir, "#   Padded Name  \n\n>   Padded description.  \n\nBody.")

      assert {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "Padded Name"
      assert skill.description == "Padded description."
    end

    test "returns error for nonexistent directory" do
      assert {:error, reason} = Skill.from_dir("/nonexistent/path/abc123")
      assert String.contains?(reason, "Not a directory")
    end

    test "returns error when SKILL.md is missing" do
      dir = tmp_dir("nomd")
      assert {:error, reason} = Skill.from_dir(dir)
      assert String.contains?(reason, "No SKILL.md")
    end

    test "returns error when path is a file, not a dir" do
      dir = tmp_dir("filepath")
      file = Path.join(dir, "somefile.txt")
      File.write!(file, "content")

      assert {:error, reason} = Skill.from_dir(file)
      assert String.contains?(reason, "Not a directory")
    end
  end

  # --- from_dir!/1 ---

  describe "from_dir!/1" do
    test "returns skill on success" do
      dir = tmp_dir("bang_ok")
      write_skill_md(dir, "# Bang Skill\n\nInstruction.")

      skill = Skill.from_dir!(dir)
      assert skill.name == "Bang Skill"
    end

    test "raises ArgumentError on failure" do
      assert_raise ArgumentError, fn ->
        Skill.from_dir!("/nonexistent/abc123")
      end
    end
  end

  # --- load_from_dir/1 ---

  describe "load_from_dir/1" do
    test "loads skills from subdirectories" do
      root = tmp_dir("root")

      skill_a = Path.join(root, "skill_a")
      skill_b = Path.join(root, "skill_b")
      File.mkdir_p!(skill_a)
      File.mkdir_p!(skill_b)
      write_skill_md(skill_a, "# Skill A\n\nInstruction A.")
      write_skill_md(skill_b, "# Skill B\n\nInstruction B.")

      assert {:ok, skills} = Skill.load_from_dir(root)
      assert length(skills) == 2
      names = Enum.map(skills, & &1.name)
      assert "Skill A" in names
      assert "Skill B" in names
    end

    test "skips subdirectories without SKILL.md" do
      root = tmp_dir("root_skip")

      good = Path.join(root, "good_skill")
      bad = Path.join(root, "not_a_skill")
      File.mkdir_p!(good)
      File.mkdir_p!(bad)
      write_skill_md(good, "# Good Skill\n\nInstruction.")
      File.write!(Path.join(bad, "README.md"), "Not a skill.")

      assert {:ok, skills} = Skill.load_from_dir(root)
      assert length(skills) == 1
      assert hd(skills).name == "Good Skill"
    end

    test "returns empty list for directory with no skill subdirs" do
      root = tmp_dir("empty_root")
      assert {:ok, []} = Skill.load_from_dir(root)
    end

    test "returns error for nonexistent root" do
      assert {:error, reason} = Skill.load_from_dir("/nonexistent/abc_xyz")
      assert String.contains?(reason, "Not a directory")
    end

    test "results are sorted by name" do
      root = tmp_dir("sorted")

      for name <- ["z_skill", "a_skill", "m_skill"] do
        dir = Path.join(root, name)
        File.mkdir_p!(dir)
        write_skill_md(dir, "# #{String.upcase(name)}\n\nInstructions.")
      end

      assert {:ok, skills} = Skill.load_from_dir(root)
      names = Enum.map(skills, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  # --- to_instruction/1 ---

  describe "to_instruction/1" do
    test "returns the instruction string" do
      skill = %Skill{name: "Test", instruction: "Do the thing.", dir: "/tmp/x"}
      assert Skill.to_instruction(skill) == "Do the thing."
    end
  end

  # --- apply_to_opts/2 ---

  describe "apply_to_opts/2" do
    test "appends skill instruction to agent instruction" do
      skill = %Skill{name: "Helper", instruction: "Be extra helpful.", dir: "/tmp/h"}
      opts = [name: "bot", model: "test", instruction: "You assist users.", tools: []]

      merged = Skill.apply_to_opts(opts, [skill])
      assert String.contains?(merged[:instruction], "You assist users.")
      assert String.contains?(merged[:instruction], "Be extra helpful.")
    end

    test "merges skill tools into agent tools" do
      tool = %{name: "my_tool", description: "A tool", parameters: %{}}
      skill = %Skill{name: "Tooled", instruction: "Use tools.", tools: [tool], dir: "/tmp/t"}
      opts = [name: "bot", model: "test", instruction: "Help.", tools: []]

      merged = Skill.apply_to_opts(opts, [skill])
      assert tool in merged[:tools]
    end

    test "handles multiple skills" do
      skill_a = %Skill{name: "A", instruction: "Instruction A.", tools: [], dir: "/tmp/a"}
      skill_b = %Skill{name: "B", instruction: "Instruction B.", tools: [], dir: "/tmp/b"}
      opts = [name: "bot", model: "test", instruction: "Base.", tools: []]

      merged = Skill.apply_to_opts(opts, [skill_a, skill_b])
      assert String.contains?(merged[:instruction], "Instruction A.")
      assert String.contains?(merged[:instruction], "Instruction B.")
    end

    test "returns opts unchanged for empty skills list" do
      opts = [name: "bot", model: "test", instruction: "Base.", tools: []]
      assert Skill.apply_to_opts(opts, []) == opts
    end
  end

  # --- Frontmatter deps parsing ---

  describe "deps frontmatter" do
    test "parses comma-separated deps and populates missing_deps" do
      dir = tmp_dir("deps_csv")

      write_skill_md(dir, """
      ---
      name: Dep Skill
      deps: nonexistent_dep_aaa, nonexistent_dep_bbb
      ---

      # Dep Skill

      Instructions.
      """)

      assert {:ok, skill} = Skill.from_dir(dir)
      assert "nonexistent_dep_aaa" in skill.missing_deps
      assert "nonexistent_dep_bbb" in skill.missing_deps
    end

    test "parses list-style deps in frontmatter" do
      dir = tmp_dir("deps_list")

      write_skill_md(dir, """
      ---
      name: List Dep Skill
      deps:
        - nonexistent_dep_ccc
        - nonexistent_dep_ddd
      ---

      Instructions.
      """)

      assert {:ok, skill} = Skill.from_dir(dir)
      assert "nonexistent_dep_ccc" in skill.missing_deps
      assert "nonexistent_dep_ddd" in skill.missing_deps
    end

    test "missing_deps is empty when deps are available" do
      dir = tmp_dir("deps_ok")

      write_skill_md(dir, """
      ---
      name: Good Dep Skill
      deps: ls
      ---

      Instructions.
      """)

      assert {:ok, skill} = Skill.from_dir(dir)
      assert skill.missing_deps == []
    end

    test "missing_deps defaults to empty when no deps declared" do
      dir = tmp_dir("no_deps")
      write_skill_md(dir, "# No Deps Skill\n\nInstructions.")

      assert {:ok, skill} = Skill.from_dir(dir)
      assert skill.missing_deps == []
    end
  end

  # --- LlmAgent integration ---

  describe "LlmAgent with skills" do
    test "agent instruction includes skill instructions" do
      dir = tmp_dir("llmagent_skill")
      write_skill_md(dir, "# Expert Mode\n\nAlways explain your reasoning.")

      {:ok, skill} = Skill.from_dir(dir)

      agent =
        ADK.Agent.LlmAgent.new(
          name: "smart_bot",
          model: "test",
          instruction: "You are a helpful assistant.",
          skills: [skill]
        )

      assert String.contains?(agent.instruction, "You are a helpful assistant.")
      assert String.contains?(agent.instruction, "Always explain your reasoning.")
    end

    test "agent tools include skill tools" do
      tool = %{name: "skill_tool", description: "From skill", parameters: %{}}

      skill = %Skill{
        name: "Tooled Skill",
        instruction: "Use the skill tool.",
        tools: [tool],
        dir: "/tmp/tooled"
      }

      agent =
        ADK.Agent.LlmAgent.new(
          name: "tooled_bot",
          model: "test",
          instruction: "Help.",
          tools: [],
          skills: [skill]
        )

      assert tool in agent.tools
    end

    test "agent with no skills is unchanged" do
      agent =
        ADK.Agent.LlmAgent.new(
          name: "plain_bot",
          model: "test",
          instruction: "Just help.",
          tools: []
        )

      assert agent.instruction == "Just help."
      assert agent.tools == []
    end
  end
end
