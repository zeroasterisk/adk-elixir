defmodule Mix.Tasks.Adk.NewParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's test_cli_create.py.

  The Python tests cover CLI project scaffolding with .env files,
  API-key vs Vertex backends, gcloud fallbacks, and click prompts.
  Elixir uses Mix tasks with EEx templates and config files instead.

  This file ports the *applicable behavioral patterns*:
  - Name validation edge cases (hyphen, spaces, special chars)
  - File generation content integrity
  - Overwrite / existing-directory semantics
  - Template rendering correctness
  - Permission / filesystem error propagation
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @tmp_dir "test/tmp_parity"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Name validation — ported from test_run_cmd_invalid_app_name
  # Python rejects "my-agent"; Elixir should too (hyphens invalid).
  # ---------------------------------------------------------------------------
  describe "name validation parity (test_run_cmd_invalid_app_name)" do
    test "rejects hyphenated name like Python's my-agent" do
      assert_raise Mix.Error, ~r/Invalid project name/, fn ->
        Mix.Tasks.Adk.New.run(["my-agent", "--path", @tmp_dir])
      end
    end

    test "rejects name with spaces" do
      # OptionParser would split "my agent" into two args on CLI,
      # but passed as single string it hits name validation instead
      assert_raise Mix.Error, ~r/Invalid project name/, fn ->
        Mix.Tasks.Adk.New.run(["my agent", "--path", @tmp_dir])
      end
    end

    test "rejects name with dots" do
      assert_raise Mix.Error, ~r/Invalid project name/, fn ->
        Mix.Tasks.Adk.New.run(["my.agent", "--path", @tmp_dir])
      end
    end

    test "rejects uppercase-only name" do
      assert_raise Mix.Error, ~r/Invalid project name/, fn ->
        Mix.Tasks.Adk.New.run(["AGENT", "--path", @tmp_dir])
      end
    end

    test "valid_name?/1 rejects hyphenated names" do
      refute Mix.Tasks.Adk.New.valid_name?("my-agent")
    end

    test "valid_name?/1 rejects names with dots" do
      refute Mix.Tasks.Adk.New.valid_name?("my.agent")
    end

    test "valid_name?/1 accepts underscore-separated names" do
      assert Mix.Tasks.Adk.New.valid_name?("my_cool_agent_3")
    end

    test "valid_name?/1 accepts single letter" do
      assert Mix.Tasks.Adk.New.valid_name?("a")
    end
  end

  # ---------------------------------------------------------------------------
  # File generation content — ported from test_generate_files_with_api_key /
  # test_generate_files_with_gcp / test_run_cmd_with_type_config
  # Python checks .env content; Elixir checks config and agent module content.
  # ---------------------------------------------------------------------------
  describe "generated file content parity" do
    test "agent module references correct model from --model flag" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run([
          "model_test",
          "--path",
          @tmp_dir,
          "--model",
          "gemini-2.0-flash-001"
        ])
      end)

      agent = File.read!(Path.join([@tmp_dir, "model_test", "lib", "model_test", "agent.ex"]))
      assert agent =~ "gemini-2.0-flash-001"
      # Ensure it doesn't contain the default model
      refute agent =~ "gemini-flash-latest"
    end

    test "config references custom model" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["config_model", "--path", @tmp_dir, "--model", "gemini-2.5-pro"])
      end)

      config = File.read!(Path.join([@tmp_dir, "config_model", "config", "config.exs"]))
      assert config =~ "gemini-2.5-pro"
    end

    test "generated mix.exs has correct app name and module" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["billing_agent", "--path", @tmp_dir])
      end)

      mix_exs = File.read!(Path.join([@tmp_dir, "billing_agent", "mix.exs"]))
      assert mix_exs =~ "BillingAgent.MixProject"
      assert mix_exs =~ "app: :billing_agent"
    end

    test "generated test file uses correct module name" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["test_gen", "--path", @tmp_dir])
      end)

      test_file =
        File.read!(Path.join([@tmp_dir, "test_gen", "test", "test_gen", "agent_test.exs"]))

      assert test_file =~ "TestGen"
    end

    test "generated README references project name" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["readme_check", "--path", @tmp_dir])
      end)

      readme = File.read!(Path.join([@tmp_dir, "readme_check", "README.md"]))
      assert readme =~ "readme_check" or readme =~ "ReadmeCheck"
    end

    test "generated application.ex has correct module" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["app_mod", "--path", @tmp_dir])
      end)

      app = File.read!(Path.join([@tmp_dir, "app_mod", "lib", "app_mod", "application.ex"]))
      assert app =~ "AppMod.Application"
    end
  end

  # ---------------------------------------------------------------------------
  # Overwrite / existing-directory — ported from test_generate_files_overwrite
  # and test_run_cmd_overwrite_reject
  # Python asks for confirmation; Elixir raises immediately.
  # ---------------------------------------------------------------------------
  describe "overwrite semantics parity (test_generate_files_overwrite)" do
    test "raises when project directory already exists with files" do
      project_dir = Path.join(@tmp_dir, "existing_proj")
      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "some_file.txt"), "existing content")

      assert_raise Mix.Error, ~r/already exists/, fn ->
        Mix.Tasks.Adk.New.run(["existing_proj", "--path", @tmp_dir])
      end
    end

    test "raises when project directory exists but is empty" do
      project_dir = Path.join(@tmp_dir, "empty_proj")
      File.mkdir_p!(project_dir)

      assert_raise Mix.Error, ~r/already exists/, fn ->
        Mix.Tasks.Adk.New.run(["empty_proj", "--path", @tmp_dir])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Template path resolution — ensures templates are findable
  # ---------------------------------------------------------------------------
  describe "template_path/0" do
    test "returns a path containing adk.new" do
      path = Mix.Tasks.Adk.New.template_path()
      assert String.contains?(path, "adk.new")
    end

    test "template directory contains expected template files" do
      path = Mix.Tasks.Adk.New.template_path()
      assert File.exists?(Path.join(path, "mix.exs.eex"))
      assert File.exists?(Path.join(path, "README.md.eex"))
      assert File.exists?(Path.join(path, "gitignore.eex"))
    end
  end

  # ---------------------------------------------------------------------------
  # No-phoenix variant — ported from type-based generation (config vs code)
  # Python has --type=config vs --type=code; Elixir has --no-phoenix.
  # ---------------------------------------------------------------------------
  describe "no-phoenix generation parity" do
    test "generates all non-router files with --no-phoenix" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["headless", "--path", @tmp_dir, "--no-phoenix"])
      end)

      project = Path.join(@tmp_dir, "headless")

      # All base files should exist
      assert File.exists?(Path.join(project, "mix.exs"))
      assert File.exists?(Path.join(project, "lib/headless.ex"))
      assert File.exists?(Path.join(project, "lib/headless/agent.ex"))
      assert File.exists?(Path.join(project, "lib/headless/tools.ex"))
      assert File.exists?(Path.join(project, "lib/headless/application.ex"))
      assert File.exists?(Path.join(project, "config/config.exs"))
      assert File.exists?(Path.join(project, "test/test_helper.exs"))
      assert File.exists?(Path.join(project, "test/headless/agent_test.exs"))

      # Router should NOT exist
      refute File.exists?(Path.join(project, "lib/headless/router.ex"))
    end

    test "no-phoenix mix.exs omits bandit dependency" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["no_web", "--path", @tmp_dir, "--no-phoenix"])
      end)

      mix_exs = File.read!(Path.join([@tmp_dir, "no_web", "mix.exs"]))
      refute mix_exs =~ ":bandit"
    end

    test "phoenix (default) mix.exs includes bandit dependency" do
      capture_io(fn ->
        Mix.Tasks.Adk.New.run(["with_web", "--path", @tmp_dir])
      end)

      mix_exs = File.read!(Path.join([@tmp_dir, "with_web", "mix.exs"]))
      assert mix_exs =~ ":bandit"
    end
  end

  # ---------------------------------------------------------------------------
  # Output messages — ported from run_cmd output checks
  # Python checks click.echo/secho output; Elixir checks Mix.shell output.
  # ---------------------------------------------------------------------------
  describe "output messages parity" do
    test "prints creating messages during generation" do
      output =
        capture_io(fn ->
          Mix.Tasks.Adk.New.run(["output_test", "--path", @tmp_dir])
        end)

      assert output =~ "creating"
      assert output =~ "mix.exs"
    end

    test "next steps include iex command" do
      output =
        capture_io(fn ->
          Mix.Tasks.Adk.New.run(["iex_test", "--path", @tmp_dir])
        end)

      assert output =~ "iex -S mix"
    end

    test "next steps include GEMINI_API_KEY export" do
      output =
        capture_io(fn ->
          Mix.Tasks.Adk.New.run(["key_test", "--path", @tmp_dir])
        end)

      assert output =~ "GEMINI_API_KEY"
    end

    test "phoenix project shows web server instructions" do
      output =
        capture_io(fn ->
          Mix.Tasks.Adk.New.run(["web_test", "--path", @tmp_dir])
        end)

      assert output =~ "Router"
    end

    test "no-phoenix project omits web server instructions" do
      output =
        capture_io(fn ->
          Mix.Tasks.Adk.New.run(["noweb_test", "--path", @tmp_dir, "--no-phoenix"])
        end)

      refute output =~ "Router"
    end
  end
end
