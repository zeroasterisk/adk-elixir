if Code.ensure_loaded?(Ecto) do
  defmodule ADK.Session.Store.Ecto do
    @moduledoc """
    Ecto-backed session store.

    Persists sessions to a relational database via the user's Ecto repo.

    ## Setup

    1. Add `ecto` and `ecto_sql` to your deps
    2. Run `mix adk.gen.migration` to generate the migration
    3. Run `mix ecto.migrate`

    ## Usage

        ADK.Session.start_link(
          app_name: "my_app",
          user_id: "user1",
          session_id: "sess1",
          store: {ADK.Session.Store.Ecto, [repo: MyApp.Repo]}
        )

    ## Configuration

    You can set a default repo in config:

        config :adk, ADK.Session.Store.Ecto, repo: MyApp.Repo
    """

    @behaviour ADK.Session.Store

    import Ecto.Query

    defmodule Schema do
      @moduledoc false
      use Ecto.Schema

      @primary_key false
      schema "adk_sessions" do
        field :app_name, :string, primary_key: true
        field :user_id, :string, primary_key: true
        field :session_id, :string, primary_key: true
        field :state, :map, default: %{}

        timestamps(type: :utc_datetime_usec)
      end

      def changeset(session \\ %__MODULE__{}, attrs) do
        session
        |> Ecto.Changeset.cast(attrs, [:app_name, :user_id, :session_id, :state])
        |> Ecto.Changeset.validate_required([:app_name, :user_id, :session_id])
      end
    end

    @impl ADK.Session.Store
    def load(app_name, user_id, session_id) do
      repo = repo!()

      case repo.get_by(Schema, app_name: app_name, user_id: user_id, session_id: session_id) do
        nil ->
          {:error, :not_found}

        record ->
          {:ok,
           %{
             id: record.session_id,
             app_name: record.app_name,
             user_id: record.user_id,
             state: record.state || %{},
             events: []
           }}
      end
    end

    @impl ADK.Session.Store
    def save(session) do
      repo = repo!()
      attrs = %{
        app_name: session.app_name,
        user_id: session.user_id,
        session_id: session.id,
        state: session.state
      }

      case repo.get_by(Schema, app_name: session.app_name, user_id: session.user_id, session_id: session.id) do
        nil ->
          %Schema{}
          |> Schema.changeset(attrs)
          |> repo.insert()
          |> case do
            {:ok, _} -> :ok
            {:error, changeset} -> {:error, changeset}
          end

        existing ->
          existing
          |> Schema.changeset(attrs)
          |> repo.update()
          |> case do
            {:ok, _} -> :ok
            {:error, changeset} -> {:error, changeset}
          end
      end
    end

    @impl ADK.Session.Store
    def delete(app_name, user_id, session_id) do
      repo = repo!()

      from(s in Schema,
        where: s.app_name == ^app_name and s.user_id == ^user_id and s.session_id == ^session_id
      )
      |> repo.delete_all()

      :ok
    end

    @impl ADK.Session.Store
    def list(app_name, user_id) do
      repo = repo!()

      from(s in Schema,
        where: s.app_name == ^app_name and s.user_id == ^user_id,
        select: s.session_id
      )
      |> repo.all()
    end

    defp repo! do
      Application.get_env(:adk, __MODULE__, [])[:repo] ||
        raise """
        No Ecto repo configured for ADK.Session.Store.Ecto.

        Set it in config:

            config :adk, ADK.Session.Store.Ecto, repo: MyApp.Repo
        """
    end
  end
end
