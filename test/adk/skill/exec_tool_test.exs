defmodule ADK.Skill.ExecToolTest do
  use ExUnit.Case, async: true

  alias ADK.Skill.ExecTool
  alias ADK.Tool.FunctionTool

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "exec_tool_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_script(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
  end

  describe "new/1" do
    test "creates FunctionTool from .sh script" do
      dir = tmp_dir()
      path = write_script(dir, "greet.sh", "# description: Greet someone\necho Hello $1")
      tool = ExecTool.new(path)

      assert %FunctionTool{} = tool
      assert tool.name == "greet"
      assert tool.description == "Greet someone"
      assert tool.parameters["properties"]["args"]
    end

    test "creates FunctionTool from .py script" do
      dir = tmp_dir()
      path = write_script(dir, "calc.py", "# description: Calculate\nimport sys\nprint(sum(map(int, sys.argv[1:])))")
      tool = ExecTool.new(path)

      assert tool.name == "calc"
      assert tool.description == "Calculate"
    end

    test "handles missing description" do
      dir = tmp_dir()
      path = write_script(dir, "nodesc.sh", "echo hi")
      tool = ExecTool.new(path)

      assert tool.name == "nodesc"
      assert tool.description == ""
    end
  end

  describe "run_script/3" do
    test "runs .sh script successfully" do
      dir = tmp_dir()
      path = write_script(dir, "echo.sh", "#!/bin/bash\necho \"hello $1\"")

      assert {:ok, "hello world"} = ExecTool.run_script(path, %{"args" => ["world"]})
    end

    test "runs .py script successfully" do
      dir = tmp_dir()
      path = write_script(dir, "add.py", "import sys\nprint(int(sys.argv[1]) + int(sys.argv[2]))")

      assert {:ok, "5"} = ExecTool.run_script(path, %{"args" => ["2", "3"]})
    end

    test "returns error on non-zero exit" do
      dir = tmp_dir()
      path = write_script(dir, "fail.sh", "#!/bin/bash\nexit 1")

      assert {:error, msg} = ExecTool.run_script(path, %{})
      assert msg =~ "exited with code 1"
    end

    test "handles empty args" do
      dir = tmp_dir()
      path = write_script(dir, "noargs.sh", "#!/bin/bash\necho done")

      assert {:ok, "done"} = ExecTool.run_script(path, %{})
    end

    test "tool can be invoked via FunctionTool.run" do
      dir = tmp_dir()
      path = write_script(dir, "ft.sh", "#!/bin/bash\necho \"got $1\"")
      tool = ExecTool.new(path)

      assert {:ok, "got foo"} = FunctionTool.run(tool, %{}, %{"args" => ["foo"]})
    end
  end
end
