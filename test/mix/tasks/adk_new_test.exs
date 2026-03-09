defmodule Mix.Tasks.Adk.NewTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @tmp_dir "test/tmp"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "validation" do
    test "rejects missing name" do
      assert_raise Mix.Error, ~r/Expected project name/, fn ->
        Mix.Tasks.Adk.New.run([])
      end
    end

    test "rejects multiple names" do
      assert_raise Mix.Error, ~r/Expected a single project name/, fn ->
        Mix.Tasks.Adk.New.run(["foo", "bar"])
      end
    end

    test "rejects invalid name" do
      assert_raise Mix.Error, ~r/Invalid project name/, fn ->
        Mix.Tasks.Adk.New.run(["FooBar", "--path", @tmp_dir])
      end
    end

    test "rejects name starting with digit" do
      assert_raise Mix.Error, ~r/Invalid project name/, fn ->
        Mix.Tasks.Adk.New.run(["123bad", "--path", @tmp_dir])
      end
    end

    test "rejects existing directory" do
      File.mkdir_p!(Path.join(@tmp_dir, "existing"))

      assert_raise Mix.Error, ~r/already exists/, fn ->
        Mix.Tasks.Adk.New.run(["existing", "--path", @tmp_dir])
      end
    end
  end

  describe "valid_name?/1" do
    test "accepts valid names" do
      assert Mix.Tasks.Adk.New.valid_name?("my_agent")
      assert Mix.Tasks.Adk.New.valid_name?("agent")
      assert Mix.Tasks.Adk.New.valid_name?("my_agent_2")
    end

    test "rejects invalid names" do
      refute Mix.Tasks.Adk.New.valid_name?("MyAgent")
      refute Mix.Tasks.Adk.New.valid_name?("1agent")
      refute Mix.Tasks.Adk.New.valid_name?("my-agent")
      refute Mix.Tasks.Adk.New.valid_name?("")
    end
  end

  describe "project generation" do
    test "creates project with default options" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["my_agent", "--path", @tmp_dir])
      end)

      project = Path.join(@tmp_dir, "my_agent")
      assert File.dir?(project)

      # Core files
      assert File.exists?(Path.join(project, "mix.exs"))
      assert File.exists?(Path.join(project, "lib/my_agent.ex"))
      assert File.exists?(Path.join(project, "lib/my_agent/agent.ex"))
      assert File.exists?(Path.join(project, "lib/my_agent/tools.ex"))
      assert File.exists?(Path.join(project, "lib/my_agent/application.ex"))
      assert File.exists?(Path.join(project, "lib/my_agent/router.ex"))
      assert File.exists?(Path.join(project, "config/config.exs"))
      assert File.exists?(Path.join(project, "config/dev.exs"))
      assert File.exists?(Path.join(project, "config/test.exs"))
      assert File.exists?(Path.join(project, "test/test_helper.exs"))
      assert File.exists?(Path.join(project, "test/my_agent/agent_test.exs"))
      assert File.exists?(Path.join(project, "README.md"))
      assert File.exists?(Path.join(project, ".gitignore"))
      assert File.exists?(Path.join(project, ".formatter.exs"))

      # Check content
      mix_exs = File.read!(Path.join(project, "mix.exs"))
      assert mix_exs =~ "MyAgent.MixProject"
      assert mix_exs =~ ":my_agent"
      assert mix_exs =~ ":adk"
      assert mix_exs =~ ":bandit"

      agent = File.read!(Path.join(project, "lib/my_agent/agent.ex"))
      assert agent =~ "MyAgent.Agent"
      assert agent =~ "gemini-2.0-flash"

      config = File.read!(Path.join(project, "config/config.exs"))
      assert config =~ "gemini-2.0-flash"
    end

    test "creates project with --no-phoenix" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["headless_agent", "--path", @tmp_dir, "--no-phoenix"])
      end)

      project = Path.join(@tmp_dir, "headless_agent")
      assert File.dir?(project)

      # No router
      refute File.exists?(Path.join(project, "lib/headless_agent/router.ex"))

      # No bandit dep
      mix_exs = File.read!(Path.join(project, "mix.exs"))
      refute mix_exs =~ ":bandit"
    end

    test "creates project with custom --model" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["custom_agent", "--path", @tmp_dir, "--model", "gemini-2.5-pro"])
      end)

      project = Path.join(@tmp_dir, "custom_agent")

      config = File.read!(Path.join(project, "config/config.exs"))
      assert config =~ "gemini-2.5-pro"

      agent = File.read!(Path.join(project, "lib/custom_agent/agent.ex"))
      assert agent =~ "gemini-2.5-pro"
    end

    test "output includes next steps" do
      output =
        capture_io(fn ->
          Mix.Tasks.Adk.New.run(["my_agent2", "--path", @tmp_dir])
        end)

      assert output =~ "cd #{@tmp_dir}/my_agent2"
      assert output =~ "mix deps.get"
      assert output =~ "mix test"
      assert output =~ "MyAgent2.Agent.run"
    end
  end
end
