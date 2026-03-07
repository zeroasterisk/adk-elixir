if Code.ensure_loaded?(Ecto) do
  defmodule Mix.Tasks.Adk.Gen.Migration do
    @moduledoc """
    Generates an Ecto migration for the ADK sessions table.

        $ mix adk.gen.migration

    The migration will be created in `priv/repo/migrations/`.

    ## Options

      * `--repo` - the repo module (defaults to the app's configured repo)

    """
    @shortdoc "Generates the ADK sessions migration"

    use Mix.Task

    import Mix.Ecto
    import Mix.Generator

    @impl Mix.Task
    def run(args) do
      no_umbrella!("adk.gen.migration")
      repos = parse_repo(args)

      Enum.each(repos, fn repo ->
        ensure_repo(repo, args)
        path = Ecto.Migrator.migrations_path(repo)

        source_path =
          :adk
          |> Application.app_dir("priv/templates/adk.gen.migration/migration.exs.eex")

        generated_file =
          EEx.eval_string(migration_template(), module: migration_module(repo))

        timestamp = timestamp()
        filename = "#{timestamp}_create_adk_sessions.exs"
        file = Path.join(path, filename)

        create_directory(path)
        create_file(file, generated_file)
      end)
    end

    defp migration_module(repo) do
      repo
      |> Module.split()
      |> Enum.drop(-1)
      |> Kernel.++(["Migrations", "CreateAdkSessions"])
      |> Module.concat()
    end

    defp timestamp do
      {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
      "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
    end

    defp pad(i) when i < 10, do: "0#{i}"
    defp pad(i), do: "#{i}"

    defp migration_template do
      """
      defmodule <%= inspect @module %> do
        use Ecto.Migration

        def change do
          create table(:adk_sessions, primary_key: false) do
            add :app_name, :string, null: false
            add :user_id, :string, null: false
            add :session_id, :string, null: false
            add :state, :map, default: "{}"

            timestamps(type: :utc_datetime_usec)
          end

          create unique_index(:adk_sessions, [:app_name, :user_id, :session_id])
          create index(:adk_sessions, [:app_name, :user_id])
        end
      end
      """
    end
  end
end
