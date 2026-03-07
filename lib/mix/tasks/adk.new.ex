defmodule Mix.Tasks.Adk.New do
  @moduledoc """
  Creates a new ADK agent project.

  ## Usage

      mix adk.new my_agent
      mix adk.new my_agent --path ./projects

  The project name must be a valid Elixir identifier (lowercase, underscores allowed).
  """
  @shortdoc "Creates a new ADK agent project"

  use Mix.Task

  @templates_path "priv/templates/adk.new"

  @impl true
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: [path: :string])

    case argv do
      [name] -> create_project(name, opts)
      [] -> Mix.raise("Expected project name. Usage: mix adk.new my_agent")
      _ -> Mix.raise("Expected a single project name. Usage: mix adk.new my_agent")
    end
  end

  defp create_project(name, opts) do
    unless valid_name?(name) do
      Mix.raise(
        "Invalid project name: #{name}. " <>
          "Must start with a lowercase letter and contain only lowercase letters, digits, and underscores."
      )
    end

    module_name = Macro.camelize(name)
    base_path = opts[:path] || "."
    project_path = Path.join(base_path, name)

    if File.dir?(project_path) do
      Mix.raise("Directory #{project_path} already exists!")
    end

    assigns = [
      app_name: name,
      module_name: module_name,
      otp_app: String.to_atom(name),
      adk_version: adk_version()
    ]

    templates = [
      {"mix.exs.eex", "mix.exs"},
      {"lib/app.ex.eex", "lib/#{name}.ex"},
      {"lib/app/agent.ex.eex", "lib/#{name}/agent.ex"},
      {"lib/app/tools.ex.eex", "lib/#{name}/tools.ex"},
      {"lib/app/application.ex.eex", "lib/#{name}/application.ex"},
      {"config/config.exs.eex", "config/config.exs"},
      {"config/dev.exs.eex", "config/dev.exs"},
      {"config/test.exs.eex", "config/test.exs"},
      {"test/test_helper.exs.eex", "test/test_helper.exs"},
      {"test/app/agent_test.exs.eex", "test/#{name}/agent_test.exs"},
      {"README.md.eex", "README.md"},
      {"gitignore.eex", ".gitignore"},
      {"formatter.exs.eex", ".formatter.exs"}
    ]

    Mix.shell().info([:green, "* creating", :reset, " #{project_path}"])

    for {template, dest} <- templates do
      dest_path = Path.join(project_path, dest)
      content = render_template(template, assigns)

      dest_path |> Path.dirname() |> File.mkdir_p!()
      File.write!(dest_path, content)
      Mix.shell().info([:green, "* creating", :reset, " #{dest}"])
    end

    Mix.shell().info("""

    Your ADK agent #{name} has been created! 🏴‍☠️

    Next steps:

        cd #{project_path}
        export GEMINI_API_KEY=your_key_here
        mix deps.get
        mix test
        iex -S mix

    Then try:

        iex> #{module_name}.Agent.run("Hello, what can you do?")

    """)
  end

  defp valid_name?(name) do
    Regex.match?(~r/^[a-z][a-z0-9_]*$/, name)
  end

  defp adk_version do
    case :application.get_key(:adk, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.1.0"
    end
  end

  defp render_template(name, assigns) do
    # Try priv dir first, fall back to relative path (for dev/test)
    template_path =
      case :code.priv_dir(:adk) do
        {:error, _} -> Path.join(@templates_path, name)
        priv -> Path.join([priv, "templates", "adk.new", name])
      end

    template_path
    |> File.read!()
    |> EEx.eval_string(assigns: assigns)
  end
end
