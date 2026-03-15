defmodule Openclaw.ArtifactStore.Ecto do
  @moduledoc """
  Ecto-backed artifact store for ADK Elixir OpenClaw.
  """
  @behaviour ADK.Artifact.Store

  import Ecto.Query

  defmodule Schema do
    @moduledoc false
    use Ecto.Schema

    schema "adk_artifacts" do
      field :app_name, :string
      field :user_id, :string
      field :session_id, :string
      field :filename, :string
      field :data, :binary
      field :content_type, :string
      field :metadata, :map, default: %{}
      field :version, :integer, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    def changeset(artifact \\ %__MODULE__{}, attrs) do
      artifact
      |> Ecto.Changeset.cast(attrs, [:app_name, :user_id, :session_id, :filename, :data, :content_type, :metadata, :version])
      |> Ecto.Changeset.validate_required([:app_name, :user_id, :session_id, :filename, :data, :content_type, :version])
    end
  end

  defp repo(opts) do
    Keyword.get(opts, :repo) || Application.get_env(:openclaw, __MODULE__, [])[:repo] || Openclaw.Repo
  end

  @impl ADK.Artifact.Store
  def save(app_name, user_id, session_id, filename, artifact, opts \\ []) do
    r = repo(opts)
    
    # Get latest version
    latest =
      from(a in Schema,
        where: a.app_name == ^app_name and a.user_id == ^user_id and a.session_id == ^session_id and a.filename == ^filename,
        order_by: [desc: a.version],
        limit: 1
      )
      |> r.one()

    new_version = if latest, do: latest.version + 1, else: 1

    attrs = %{
      app_name: app_name,
      user_id: user_id,
      session_id: session_id,
      filename: filename,
      data: artifact.data,
      content_type: artifact.content_type,
      metadata: Map.get(artifact, :metadata, %{}),
      version: new_version
    }

    %Schema{}
    |> Schema.changeset(attrs)
    |> r.insert()
    |> case do
      {:ok, _record} -> {:ok, new_version}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl ADK.Artifact.Store
  def load(app_name, user_id, session_id, filename, opts \\ []) do
    r = repo(opts)
    version = Keyword.get(opts, :version)

    query =
      from(a in Schema,
        where: a.app_name == ^app_name and a.user_id == ^user_id and a.session_id == ^session_id and a.filename == ^filename,
        order_by: [desc: a.version],
        limit: 1
      )
      
    query = if version, do: from(q in query, where: q.version == ^version), else: query

    case r.one(query) do
      nil -> :not_found
      record ->
        {:ok, %{
          data: record.data,
          content_type: record.content_type,
          metadata: record.metadata || %{}
        }}
    end
  end

  @impl ADK.Artifact.Store
  def list(app_name, user_id, session_id, opts \\ []) do
    r = repo(opts)

    filenames =
      from(a in Schema,
        where: a.app_name == ^app_name and a.user_id == ^user_id and a.session_id == ^session_id,
        select: a.filename,
        distinct: true
      )
      |> r.all()

    {:ok, filenames}
  end

  @impl ADK.Artifact.Store
  def delete(app_name, user_id, session_id, filename, opts \\ []) do
    r = repo(opts)

    from(a in Schema,
      where: a.app_name == ^app_name and a.user_id == ^user_id and a.session_id == ^session_id and a.filename == ^filename
    )
    |> r.delete_all()

    :ok
  end
end
