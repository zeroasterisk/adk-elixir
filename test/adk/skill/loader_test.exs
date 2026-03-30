defmodule ADK.Skill.LoaderTest do
  use ExUnit.Case, async: true

  alias ADK.Skill.Loader

  defp tmp_skill_dir(name \\ "loader_test") do
    dir = Path.join(System.tmp_dir!(), "skill_#{name}_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "discover_tools/1" do
    test "discovers .sh and .py scripts" do
      dir = tmp_skill_dir()
      tools_dir = Path.join(dir, "tools")
      File.mkdir_p!(tools_dir)

      File.write!(Path.join(tools_dir, "hello.sh"), "# description: Say hello\necho hi")
      File.write!(Path.join(tools_dir, "calc.py"), "# description: Calculate\nprint(42)")

      tools = Loader.discover_tools(dir)
      assert length(tools) == 2
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["calc", "hello"]
    end

    test "returns empty list when no tools dir" do
      dir = tmp_skill_dir("no_tools")
      assert Loader.discover_tools(dir) == []
    end

    test "returns empty list for empty tools dir" do
      dir = tmp_skill_dir("empty_tools")
      File.mkdir_p!(Path.join(dir, "tools"))
      assert Loader.discover_tools(dir) == []
    end

    test "ignores non-script files" do
      dir = tmp_skill_dir("ignore")
      tools_dir = Path.join(dir, "tools")
      File.mkdir_p!(tools_dir)
      File.write!(Path.join(tools_dir, "readme.md"), "# Readme")
      File.write!(Path.join(tools_dir, "data.json"), "{}")

      assert Loader.discover_tools(dir) == []
    end
  end

  describe "load_auth/1" do
    test "parses auth.json" do
      dir = tmp_skill_dir("auth")

      File.write!(
        Path.join(dir, "auth.json"),
        Jason.encode!(%{
          "credentials" => [
            %{"name" => "github_token", "env_var" => "GITHUB_TOKEN", "required" => true},
            %{"name" => "slack_oauth", "env_var" => "SLACK_TOKEN", "required" => false}
          ]
        })
      )

      auth = Loader.load_auth(dir)
      assert length(auth) == 2
      assert hd(auth)["name"] == "github_token"
      assert hd(auth)["required"] == true
    end

    test "returns empty list when no auth.json" do
      dir = tmp_skill_dir("no_auth")
      assert Loader.load_auth(dir) == []
    end

    test "handles malformed auth.json" do
      dir = tmp_skill_dir("bad_auth")
      File.write!(Path.join(dir, "auth.json"), "not json")
      assert Loader.load_auth(dir) == []
    end
  end

  describe "parse_mcp_config/1" do
    test "parses valid mcp.json" do
      dir = tmp_skill_dir("mcp")
      path = Path.join(dir, "mcp.json")

      File.write!(
        path,
        Jason.encode!(%{
          "servers" => [
            %{
              "name" => "filesystem",
              "command" => "npx",
              "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
              "tool_filter" => ["read_file"]
            }
          ]
        })
      )

      assert {:ok, [server]} = Loader.parse_mcp_config(path)
      assert server["name"] == "filesystem"
      assert server["tool_filter"] == ["read_file"]
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Loader.parse_mcp_config("/nonexistent/mcp.json")
    end

    test "returns error for malformed json" do
      dir = tmp_skill_dir("bad_mcp")
      path = Path.join(dir, "mcp.json")
      File.write!(path, "nope")
      assert {:error, :malformed} = Loader.parse_mcp_config(path)
    end
  end

  describe "load/1" do
    test "loads tools and auth from a skill directory" do
      dir = tmp_skill_dir("full")
      tools_dir = Path.join(dir, "tools")
      File.mkdir_p!(tools_dir)
      File.write!(Path.join(tools_dir, "helper.sh"), "# description: Help\necho help")

      File.write!(
        Path.join(dir, "auth.json"),
        Jason.encode!(%{
          "credentials" => [%{"name" => "token", "env_var" => "TOKEN", "required" => true}]
        })
      )

      result = Loader.load(dir)
      assert length(result.tools) == 1
      assert hd(result.tools).name == "helper"
      assert length(result.auth_requirements) == 1
      assert result.mcp_toolsets == []
      assert result.supervisor == nil
    end
  end
end
