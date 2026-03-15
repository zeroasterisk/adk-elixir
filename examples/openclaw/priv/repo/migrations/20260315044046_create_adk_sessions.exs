defmodule Openclaw.Repo.Migrations.CreateAdkSessions do
  use Ecto.Migration

  def change do
    create table(:adk_sessions, primary_key: false) do
      add :app_name, :string, primary_key: true
      add :user_id, :string, primary_key: true
      add :session_id, :string, primary_key: true
      add :state, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end
  end
end
