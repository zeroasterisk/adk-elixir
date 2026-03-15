defmodule Openclaw.Repo.Migrations.CreateAdkArtifacts do
  use Ecto.Migration

  def change do
    create table(:adk_artifacts) do
      add :app_name, :string, null: false
      add :user_id, :string, null: false
      add :session_id, :string, null: false
      add :filename, :string, null: false
      add :data, :binary, null: false
      add :content_type, :string, null: false
      add :metadata, :map, default: %{}
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:adk_artifacts, [:app_name, :user_id, :session_id])
    create unique_index(:adk_artifacts, [:app_name, :user_id, :session_id, :filename, :version])
  end
end
