defmodule ADK.Workflow.Checkpoint.EctoStore do
  @moduledoc """
  Ecto-backed checkpoint store for durable workflow state persistence.

  Requires an Ecto repo and a `workflow_checkpoints` table. This module
  compiles unconditionally but operations require a running Ecto repo.

  ## Migration

      create table(:workflow_checkpoints) do
        add :workflow_id, :string, null: false
        add :node_id, :string, null: false
        add :status, :string, null: false
        add :output, :map
        timestamps()
      end

      create index(:workflow_checkpoints, [:workflow_id])
      create unique_index(:workflow_checkpoints, [:workflow_id, :node_id])
  """

  @behaviour ADK.Workflow.Checkpoint

  @doc """
  Create a new Ecto checkpoint store with the given repo module.

  ## Examples

      store = ADK.Workflow.Checkpoint.EctoStore.new(MyApp.Repo)
  """
  @spec new(module()) :: %{module: module(), store: module()}
  def new(repo) do
    %{module: __MODULE__, store: __MODULE__, repo: repo}
  end

  @impl true
  @spec save(String.t(), atom() | String.t(), atom(), any()) :: no_return()
  def save(_workflow_id, _node_id, _status, _output) do
    raise "EctoStore.save/4 requires a repo. Use save_with_repo/5 or configure via ADK.Workflow options."
  end

  @impl true
  @spec load(String.t(), atom() | String.t()) :: no_return()
  def load(_workflow_id, _node_id) do
    raise "EctoStore.load/2 requires a repo. Use load_with_repo/3."
  end

  @impl true
  @spec load_all(String.t()) :: no_return()
  def load_all(_workflow_id) do
    raise "EctoStore.load_all/1 requires a repo. Use load_all_with_repo/2."
  end

  @impl true
  @spec completed_nodes(String.t()) :: no_return()
  def completed_nodes(_workflow_id) do
    raise "EctoStore.completed_nodes/1 requires a repo."
  end

  @impl true
  @spec clear(String.t()) :: no_return()
  def clear(_workflow_id) do
    raise "EctoStore.clear/1 requires a repo."
  end

  @doc """
  Save a checkpoint using the given Ecto repo.
  """
  @spec save_with_repo(module(), String.t(), atom() | String.t(), atom(), any()) ::
          :ok | {:error, term()}
  def save_with_repo(repo, workflow_id, node_id, status, output) do
    node_str = to_string(node_id)
    status_str = to_string(status)

    case repo.insert_or_update(
           %{
             workflow_id: workflow_id,
             node_id: node_str,
             status: status_str,
             output: output
           },
           on_conflict: :replace_all,
           conflict_target: [:workflow_id, :node_id]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Load a checkpoint using the given Ecto repo.

  Requires Ecto as a dependency. Uses raw Ecto.Query for the lookup.
  """
  @spec load_with_repo(module(), String.t(), atom() | String.t()) :: {:ok, map()} | :not_found
  def load_with_repo(repo, workflow_id, node_id) do
    node_str = to_string(node_id)

    # Use Ecto.Adapters.SQL.query! to avoid compile-time dependency on Ecto.Query macros
    case repo.query(
           "SELECT workflow_id, node_id, status, output FROM workflow_checkpoints WHERE workflow_id = ?1 AND node_id = ?2",
           [workflow_id, node_str]
         ) do
      {:ok, %{rows: [[wid, nid, status, output] | _]}} ->
        {:ok, %{workflow_id: wid, node_id: nid, status: status, output: output}}

      _ ->
        :not_found
    end
  rescue
    _ -> :not_found
  end
end
