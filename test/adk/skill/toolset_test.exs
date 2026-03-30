defmodule ADK.Skill.ToolsetTest do
  use ExUnit.Case, async: true

  alias ADK.Skill
  alias ADK.Skill.Toolset
  alias ADK.Skill.Script
  alias ADK.Tool.FunctionTool

  defp make_skill(name, opts \\ []) do
    dir =
      Keyword.get(
        opts,
        :dir,
        Path.join(System.tmp_dir!(), "skill_#{name}_#{:rand.uniform(100_000)}")
      )

    File.mkdir_p!(dir)

    desc = Keyword.get(opts, :description, "Description for #{name}")
    instruction = Keyword.get(opts, :instruction, "Full instructions for #{name}.")

    %Skill{
      name: name,
      description: desc,
      instruction: instruction,
      tools: [],
      dir: dir
    }
  end

  describe "Toolset.new/1" do
    test "creates a toolset from skills" do
      toolset = Toolset.new([make_skill("alpha"), make_skill("beta")])
      assert %Toolset{} = toolset
      assert map_size(toolset.skills) == 2
    end

    test "raises on duplicate skill names" do
      assert_raise ArgumentError, ~r/Duplicate skill name/, fn ->
        Toolset.new([make_skill("same"), make_skill("same")])
      end
    end

    test "works with empty list" do
      toolset = Toolset.new([])
      assert toolset.skills == %{}
    end
  end

  describe "list_skills tool" do
    test "returns names and descriptions only" do
      toolset = Toolset.new([make_skill("seo"), make_skill("blog")])
      [list_tool | _] = Toolset.tools(toolset)

      assert list_tool.name == "list_skills"
      {:ok, result} = FunctionTool.run(list_tool, %{}, %{})
      assert result =~ "seo"
      assert result =~ "blog"
      assert result =~ "Description for seo"
      assert result =~ "Description for blog"
      # Should NOT contain full instructions
      refute result =~ "Full instructions"
    end
  end

  describe "load_skill tool" do
    test "returns full instructions for valid name" do
      toolset = Toolset.new([make_skill("writer", instruction: "Write amazing content.")])
      [_, load_tool | _] = Toolset.tools(toolset)

      assert load_tool.name == "load_skill"
      {:ok, result} = FunctionTool.run(load_tool, %{}, %{"name" => "writer"})
      assert result == "Write amazing content."
    end

    test "returns error for unknown skill" do
      toolset = Toolset.new([make_skill("real")])
      [_, load_tool | _] = Toolset.tools(toolset)

      {:error, msg} = FunctionTool.run(load_tool, %{}, %{"name" => "fake"})
      assert msg =~ "Unknown skill"
    end
  end

  describe "load_skill_resource tool" do
    test "reads from references/ directory" do
      dir = Path.join(System.tmp_dir!(), "skill_res_#{:rand.uniform(100_000)}")
      refs_dir = Path.join(dir, "references")
      File.mkdir_p!(refs_dir)
      File.write!(Path.join(refs_dir, "example.txt"), "Hello resource!")

      skill = make_skill("docs", dir: dir)
      toolset = Toolset.new([skill])
      [_, _, resource_tool] = Toolset.tools(toolset)

      assert resource_tool.name == "load_skill_resource"

      {:ok, result} =
        FunctionTool.run(resource_tool, %{}, %{"name" => "docs", "path" => "example.txt"})

      assert result == "Hello resource!"
    end

    test "rejects path traversal" do
      skill = make_skill("safe")
      toolset = Toolset.new([skill])
      [_, _, resource_tool] = Toolset.tools(toolset)

      {:error, msg} =
        FunctionTool.run(resource_tool, %{}, %{"name" => "safe", "path" => "../../../etc/passwd"})

      assert msg =~ "Path traversal"
    end

    test "returns error for missing file" do
      skill = make_skill("empty")
      toolset = Toolset.new([skill])
      [_, _, resource_tool] = Toolset.tools(toolset)

      {:error, msg} =
        FunctionTool.run(resource_tool, %{}, %{"name" => "empty", "path" => "nope.txt"})

      assert msg =~ "Cannot read"
    end
  end

  describe "YAML frontmatter parsing" do
    test "parses name and description from frontmatter" do
      dir = Path.join(System.tmp_dir!(), "fm_skill_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: seo-checklist
      description: SEO optimization checklist for blog posts.
      trust: confirm
      ---

      # Instructions

      Check all the SEO things.
      """)

      {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "seo-checklist"
      assert skill.description == "SEO optimization checklist for blog posts."
    end

    test "falls back to heading/blockquote when no frontmatter" do
      dir = Path.join(System.tmp_dir!(), "nofm_skill_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      # Blog Writer

      > Writes blog posts.

      Do the writing.
      """)

      {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "Blog Writer"
      assert skill.description == "Writes blog posts."
    end

    test "frontmatter name overrides heading" do
      dir = Path.join(System.tmp_dir!(), "override_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: custom-name
      ---

      # Heading Name

      > Some desc.

      Instructions.
      """)

      {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "custom-name"
      # Description falls through to blockquote since not in frontmatter
      assert skill.description == "Some desc."
    end
  end

  describe "Script discovery" do
    test "discovers .sh, .py, and .exs files" do
      dir = Path.join(System.tmp_dir!(), "script_disc_#{:rand.uniform(100_000)}")
      scripts_dir = Path.join(dir, "scripts")
      File.mkdir_p!(scripts_dir)

      File.write!(Path.join(scripts_dir, "lint.sh"), "# Lint the code\necho ok")
      File.write!(Path.join(scripts_dir, "format.py"), "# Format output\nprint('ok')")
      File.write!(Path.join(scripts_dir, "check.exs"), "# Check things\n\"ok\"")

      result = Script.discover(dir)
      names = Enum.map(result.tools, & &1.name)
      assert "run_check" in names
      assert "run_format" in names
      assert "run_lint" in names
    end

    test "extracts description from first comment line" do
      dir = Path.join(System.tmp_dir!(), "script_desc_#{:rand.uniform(100_000)}")
      scripts_dir = Path.join(dir, "scripts")
      File.mkdir_p!(scripts_dir)

      File.write!(Path.join(scripts_dir, "greet.py"), "# Say hello to the world\nprint('hi')")

      [tool] = Script.discover(dir).tools
      assert tool.description == "Say hello to the world"
    end

    test "defaults description when no comment" do
      dir = Path.join(System.tmp_dir!(), "script_nocomment_#{:rand.uniform(100_000)}")
      scripts_dir = Path.join(dir, "scripts")
      File.mkdir_p!(scripts_dir)

      File.write!(Path.join(scripts_dir, "bare.sh"), "echo bare")

      [tool] = Script.discover(dir).tools
      assert tool.description == "Run bare.sh"
    end

    test "discovers mcp.json config" do
      dir = Path.join(System.tmp_dir!(), "script_mcp_#{:rand.uniform(100_000)}")
      scripts_dir = Path.join(dir, "scripts")
      File.mkdir_p!(scripts_dir)

      File.write!(
        Path.join(scripts_dir, "mcp.json"),
        Jason.encode!(%{
          "command" => "npx",
          "args" => ["-y", "@modelcontextprotocol/server-filesystem"]
        })
      )

      result = Script.discover(dir)
      assert length(result.mcp_configs) == 1
      assert hd(result.mcp_configs)["command"] == "npx"
    end

    test "returns empty for dir without scripts/" do
      dir = Path.join(System.tmp_dir!(), "script_none_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      result = Script.discover(dir)
      assert result.tools == []
      assert result.mcp_configs == []
    end
  end

  describe "Script execution" do
    test "executes .sh script" do
      dir = Path.join(System.tmp_dir!(), "exec_sh_#{:rand.uniform(100_000)}")
      scripts_dir = Path.join(dir, "scripts")
      File.mkdir_p!(scripts_dir)

      path = Path.join(scripts_dir, "echo.sh")
      File.write!(path, "#!/bin/bash\necho \"hello $1\"")
      File.chmod!(path, 0o755)

      [tool] = Script.discover(dir).tools
      {:ok, result} = FunctionTool.run(tool, %{}, %{"input" => "world"})
      assert result == "hello world"
    end

    test "executes .py script" do
      dir = Path.join(System.tmp_dir!(), "exec_py_#{:rand.uniform(100_000)}")
      scripts_dir = Path.join(dir, "scripts")
      File.mkdir_p!(scripts_dir)

      path = Path.join(scripts_dir, "greet.py")
      File.write!(path, "import sys\nprint(f'hi {sys.argv[1] if len(sys.argv) > 1 else \"\"}')")

      [tool] = Script.discover(dir).tools
      {:ok, result} = FunctionTool.run(tool, %{}, %{"input" => "alice"})
      assert result == "hi alice"
    end

    test "executes .exs script" do
      dir = Path.join(System.tmp_dir!(), "exec_exs_#{:rand.uniform(100_000)}")
      scripts_dir = Path.join(dir, "scripts")
      File.mkdir_p!(scripts_dir)

      path = Path.join(scripts_dir, "calc.exs")
      File.write!(path, "\"result: 42\"")

      [tool] = Script.discover(dir).tools
      {:ok, result} = FunctionTool.run(tool, %{}, %{"input" => ""})
      assert result == "result: 42"
    end
  end

  describe "from_dir with scripts/" do
    test "populates skill.tools with discovered scripts" do
      dir = Path.join(System.tmp_dir!(), "skill_scripts_#{:rand.uniform(100_000)}")
      scripts_dir = Path.join(dir, "scripts")
      File.mkdir_p!(scripts_dir)

      File.write!(
        Path.join(dir, "SKILL.md"),
        "# Scripted\n\n> Has scripts.\n\nDo scripted things."
      )

      File.write!(Path.join(scripts_dir, "helper.sh"), "# Help out\necho help")

      {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "Scripted"
      tool_names = Enum.map(skill.tools, & &1.name)
      assert "run_helper" in tool_names
    end
  end
end
