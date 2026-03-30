defmodule ADK.Skill.IntegrationTest do
  use ExUnit.Case, async: true

  alias ADK.Skill

  defp tmp_skill_dir(name) do
    dir = Path.join(System.tmp_dir!(), "skill_int_#{name}_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "from_dir/1 with tools" do
    test "loads skill with discovered tools" do
      dir = tmp_skill_dir("with_tools")
      tools_dir = Path.join(dir, "tools")
      File.mkdir_p!(tools_dir)

      File.write!(Path.join(dir, "SKILL.md"), "# My Skill\n\n> A skill with tools.\n\nDo things.")
      File.write!(Path.join(tools_dir, "greet.sh"), "# description: Greet\necho Hello $1")
      File.write!(Path.join(tools_dir, "calc.py"), "# description: Calculate\nprint(42)")

      assert {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "My Skill"
      assert skill.description == "A skill with tools."
      assert length(skill.tools) == 2
      assert skill.mcp_toolsets == []
      assert skill.auth_requirements == []
    end

    test "loads skill with auth requirements" do
      dir = tmp_skill_dir("with_auth")
      File.write!(Path.join(dir, "SKILL.md"), "# Auth Skill\n\nNeeds auth.")

      File.write!(
        Path.join(dir, "auth.json"),
        Jason.encode!(%{
          "credentials" => [
            %{"name" => "api_key", "env_var" => "API_KEY", "required" => true}
          ]
        })
      )

      assert {:ok, skill} = Skill.from_dir(dir)
      assert length(skill.auth_requirements) == 1
      assert hd(skill.auth_requirements)["name"] == "api_key"
    end
  end

  describe "apply_to_opts/2 with tools" do
    test "merges skill tools into opts" do
      dir = tmp_skill_dir("apply")
      tools_dir = Path.join(dir, "tools")
      File.mkdir_p!(tools_dir)

      File.write!(Path.join(dir, "SKILL.md"), "# Apply Skill\n\nBe helpful.")
      File.write!(Path.join(tools_dir, "helper.sh"), "# description: Help\necho help")

      {:ok, skill} = Skill.from_dir(dir)

      opts = [name: "bot", model: "test", instruction: "Base.", tools: []]
      merged = Skill.apply_to_opts(opts, [skill])

      assert String.contains?(merged[:instruction], "Be helpful.")
      assert length(merged[:tools]) == 1
      assert hd(merged[:tools]).name == "helper"
    end
  end

  describe "stop/1" do
    test "stops skill with no supervisor" do
      dir = tmp_skill_dir("stop_none")
      File.write!(Path.join(dir, "SKILL.md"), "# Simple\n\nJust text.")

      {:ok, skill} = Skill.from_dir(dir)
      assert :ok = Skill.stop(skill)
    end
  end

  describe "backward compatibility" do
    test "existing API still works with plain SKILL.md" do
      dir = tmp_skill_dir("compat")
      File.write!(Path.join(dir, "SKILL.md"), "# Compat Skill\n\n> Old style.\n\nDo things.")

      {:ok, skill} = Skill.from_dir(dir)
      assert skill.name == "Compat Skill"
      assert skill.description == "Old style."
      assert skill.tools == []
      assert skill.mcp_toolsets == []
      assert skill.auth_requirements == []
    end

    test "load_from_dir still works" do
      root = tmp_skill_dir("compat_root")
      sub = Path.join(root, "my_skill")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "SKILL.md"), "# Sub Skill\n\nInstruction.")

      {:ok, skills} = Skill.load_from_dir(root)
      assert length(skills) == 1
      assert hd(skills).name == "Sub Skill"
    end
  end
end
