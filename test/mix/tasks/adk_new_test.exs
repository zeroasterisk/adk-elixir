defmodule Mix.Tasks.Adk.NewTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "creates a new project with expected files", %{tmp_dir: tmp_dir} do
    Mix.Tasks.Adk.New.run(["test_agent", "--path", tmp_dir])

    project_path = Path.join(tmp_dir, "test_agent")
    assert File.dir?(project_path)

    expected_files = [
      "mix.exs",
      "lib/test_agent.ex",
      "lib/test_agent/agent.ex",
      "lib/test_agent/tools.ex",
      "lib/test_agent/application.ex",
      "config/config.exs",
      "config/dev.exs",
      "config/test.exs",
      "test/test_helper.exs",
      "test/test_agent/agent_test.exs",
      "README.md",
      ".gitignore",
      ".formatter.exs"
    ]

    for file <- expected_files do
      assert File.exists?(Path.join(project_path, file)), "Expected #{file} to exist"
    end
  end

  test "generated mix.exs contains correct module name", %{tmp_dir: tmp_dir} do
    Mix.Tasks.Adk.New.run(["my_cool_agent", "--path", tmp_dir])

    mix_content = File.read!(Path.join(tmp_dir, "my_cool_agent/mix.exs"))
    assert mix_content =~ "MyCoolAgent.MixProject"
    assert mix_content =~ "app: :my_cool_agent"
    assert mix_content =~ "{:adk,"
  end

  test "generated agent uses correct module name", %{tmp_dir: tmp_dir} do
    Mix.Tasks.Adk.New.run(["pirate_bot", "--path", tmp_dir])

    agent_content = File.read!(Path.join(tmp_dir, "pirate_bot/lib/pirate_bot/agent.ex"))
    assert agent_content =~ "defmodule PirateBot.Agent"
    assert agent_content =~ "PirateBot.Tools.greeting_tool()"
  end

  test "raises on invalid project name", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/Invalid project name/, fn ->
      Mix.Tasks.Adk.New.run(["InvalidName", "--path", tmp_dir])
    end

    assert_raise Mix.Error, ~r/Invalid project name/, fn ->
      Mix.Tasks.Adk.New.run(["123bad", "--path", tmp_dir])
    end
  end

  test "raises when no name given" do
    assert_raise Mix.Error, ~r/Expected project name/, fn ->
      Mix.Tasks.Adk.New.run([])
    end
  end

  test "raises when directory already exists", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "existing"))

    assert_raise Mix.Error, ~r/already exists/, fn ->
      Mix.Tasks.Adk.New.run(["existing", "--path", tmp_dir])
    end
  end
end
