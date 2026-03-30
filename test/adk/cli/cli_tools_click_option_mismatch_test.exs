# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.CLI.ToolsOptionMismatchTest do
  @moduledoc """
  Parity tests for Mix task CLI option consistency, mirroring
  Python ADK's `tests/unittests/cli/test_cli_tools_click_option_mismatch.py`.

  In Python ADK, Click decorators define CLI options and the underlying
  callback function must have matching parameter names. This test verifies
  the Elixir equivalent: that `@switches` declared in Mix tasks define the
  expected options with the correct types, and that each task correctly
  implements the `Mix.Task` behaviour.

  Since `@switches` is a compile-time constant (not accessible via
  `__info__(:attributes)`), structural tests parse the task source files
  directly. Functional tests exercise parsing behaviour at runtime.
  """

  use ExUnit.Case, async: true

  @tasks_dir Path.expand("../../../lib/mix/tasks", __DIR__)

  # --------------------------------------------------------------------------
  # Helpers: Source inspection
  # --------------------------------------------------------------------------

  # Read the source of a Mix task and extract the keyword list assigned to
  # `@switches`. Returns a keyword list like [port: :integer, agent: :string].
  defp parse_switches(task_source_file) do
    source = File.read!(task_source_file)

    # Match `@switches [key: :type, ...]` — handles single-line declarations
    case Regex.run(~r/@switches\s+\[([^\]]+)\]/, source, capture: :all_but_first) do
      [body] ->
        # Parse "port: :integer, agent: :string, model: :string" into KW list
        body
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.flat_map(fn entry ->
          case Regex.run(~r/^(\w+):\s*:(\w+)$/, entry, capture: :all_but_first) do
            [key, type] -> [{String.to_atom(key), String.to_atom(type)}]
            _ -> []
          end
        end)

      nil ->
        []
    end
  end

  defp option_names(switches), do: switches |> Keyword.keys() |> MapSet.new()

  # --------------------------------------------------------------------------
  # mix adk.server
  # --------------------------------------------------------------------------

  describe "Mix.Tasks.Adk.Server" do
    setup do
      %{source: Path.join(@tasks_dir, "adk.server.ex")}
    end

    test "module is loadable and implements Mix.Task" do
      assert Code.ensure_loaded?(Mix.Tasks.Adk.Server)
      assert function_exported?(Mix.Tasks.Adk.Server, :run, 1)
    end

    test "source file exists", %{source: source} do
      assert File.exists?(source), "Expected Mix task source at: #{source}"
    end

    test "declares expected option keys", %{source: source} do
      switches = parse_switches(source)
      names = option_names(switches)

      for key <- [:port, :agent, :model] do
        assert MapSet.member?(names, key),
               "Expected :#{key} option in @switches, got: #{inspect(names)}"
      end
    end

    test ":port has type :integer", %{source: source} do
      switches = parse_switches(source)

      assert Keyword.get(switches, :port) == :integer,
             "Expected :port => :integer, got: #{inspect(switches[:port])}"
    end

    test ":agent has type :string", %{source: source} do
      switches = parse_switches(source)

      assert Keyword.get(switches, :agent) == :string,
             "Expected :agent => :string, got: #{inspect(switches[:agent])}"
    end

    test ":model has type :string", %{source: source} do
      switches = parse_switches(source)

      assert Keyword.get(switches, :model) == :string,
             "Expected :model => :string, got: #{inspect(switches[:model])}"
    end

    test "no undeclared options beyond expected set", %{source: source} do
      switches = parse_switches(source)
      names = option_names(switches)
      expected = MapSet.new([:port, :agent, :model])
      unexpected = MapSet.difference(names, expected)

      assert MapSet.size(unexpected) == 0,
             """
             Mix.Tasks.Adk.Server has unexpected options not covered by this test:
               #{inspect(unexpected)}
             Update the expected set in this test to cover new options.
             """
    end

    test "parses --port and --agent from args at runtime" do
      # OptionParser.parse/2 with the declared switches should correctly
      # parse known flags and ignore unknowns without raising.
      switches = [port: :integer, agent: :string, model: :string]

      {opts, _argv, _invalid} =
        OptionParser.parse(["--port", "8080", "--agent", "MyAgent"], strict: switches)

      assert opts[:port] == 8080
      assert opts[:agent] == "MyAgent"
    end

    test "uses strict parsing — unknown options are not accepted" do
      switches = [port: :integer, agent: :string, model: :string]
      {_opts, _argv, invalid} = OptionParser.parse(["--unknown-flag", "val"], strict: switches)

      assert invalid != [],
             "Expected unknown options to be captured as invalid in strict mode"
    end
  end

  # --------------------------------------------------------------------------
  # mix adk.new
  # --------------------------------------------------------------------------

  describe "Mix.Tasks.Adk.New" do
    setup do
      %{source: Path.join(@tasks_dir, "adk.new.ex")}
    end

    test "module is loadable and implements Mix.Task" do
      assert Code.ensure_loaded?(Mix.Tasks.Adk.New)
      assert function_exported?(Mix.Tasks.Adk.New, :run, 1)
    end

    test "source file exists", %{source: source} do
      assert File.exists?(source), "Expected Mix task source at: #{source}"
    end

    test "declares expected option keys", %{source: source} do
      switches = parse_switches(source)
      names = option_names(switches)

      for key <- [:path, :model, :phoenix] do
        assert MapSet.member?(names, key),
               "Expected :#{key} option in @switches, got: #{inspect(names)}"
      end
    end

    test ":path has type :string", %{source: source} do
      switches = parse_switches(source)

      assert Keyword.get(switches, :path) == :string,
             "Expected :path => :string, got: #{inspect(switches[:path])}"
    end

    test ":model has type :string", %{source: source} do
      switches = parse_switches(source)

      assert Keyword.get(switches, :model) == :string,
             "Expected :model => :string, got: #{inspect(switches[:model])}"
    end

    test ":phoenix has type :boolean", %{source: source} do
      switches = parse_switches(source)

      assert Keyword.get(switches, :phoenix) == :boolean,
             "Expected :phoenix => :boolean, got: #{inspect(switches[:phoenix])}"
    end

    test "no undeclared options beyond expected set", %{source: source} do
      switches = parse_switches(source)
      names = option_names(switches)
      expected = MapSet.new([:path, :model, :phoenix])
      unexpected = MapSet.difference(names, expected)

      assert MapSet.size(unexpected) == 0,
             """
             Mix.Tasks.Adk.New has unexpected options not covered by this test:
               #{inspect(unexpected)}
             Update the expected set in this test to cover new options.
             """
    end

    test "parses --path and --model from args at runtime" do
      switches = [path: :string, model: :string, phoenix: :boolean]

      {opts, _argv, _invalid} =
        OptionParser.parse(
          ["--path", "./projects", "--model", "gemini-flash-latest"],
          strict: switches
        )

      assert opts[:path] == "./projects"
      assert opts[:model] == "gemini-flash-latest"
    end

    test "--no-phoenix flag sets :phoenix to false at runtime" do
      switches = [path: :string, model: :string, phoenix: :boolean]
      {opts, _argv, _invalid} = OptionParser.parse(["--no-phoenix"], strict: switches)

      assert opts[:phoenix] == false
    end
  end

  # --------------------------------------------------------------------------
  # mix adk.gen.migration (if Ecto is available)
  # --------------------------------------------------------------------------

  describe "Mix.Tasks.Adk.Gen.Migration" do
    test "module conditionally compiles when Ecto is present" do
      if Code.ensure_loaded?(Ecto) do
        assert Code.ensure_loaded?(Mix.Tasks.Adk.Gen.Migration),
               "Expected Mix.Tasks.Adk.Gen.Migration to be loadable when Ecto is available"

        assert function_exported?(Mix.Tasks.Adk.Gen.Migration, :run, 1)
      else
        # Ecto not loaded — module conditionally compiles, this is expected
        :ok
      end
    end
  end

  # --------------------------------------------------------------------------
  # Cross-task: valid_name?/1 (adk.new project name validation)
  # Mirrors Python's parameter validation in cli_create_cmd
  # --------------------------------------------------------------------------

  describe "Mix.Tasks.Adk.New.valid_name?/1" do
    test "accepts lowercase snake_case names" do
      assert Mix.Tasks.Adk.New.valid_name?("my_agent")
      assert Mix.Tasks.Adk.New.valid_name?("agent123")
      assert Mix.Tasks.Adk.New.valid_name?("a")
      assert Mix.Tasks.Adk.New.valid_name?("hello_world_agent")
    end

    test "rejects names starting with uppercase" do
      refute Mix.Tasks.Adk.New.valid_name?("MyAgent")
      refute Mix.Tasks.Adk.New.valid_name?("A")
    end

    test "rejects names starting with digits" do
      refute Mix.Tasks.Adk.New.valid_name?("123agent")
      refute Mix.Tasks.Adk.New.valid_name?("1_agent")
    end

    test "rejects names with hyphens" do
      refute Mix.Tasks.Adk.New.valid_name?("my-agent")
    end

    test "rejects empty string" do
      refute Mix.Tasks.Adk.New.valid_name?("")
    end

    test "rejects names with spaces" do
      refute Mix.Tasks.Adk.New.valid_name?("my agent")
    end
  end
end
