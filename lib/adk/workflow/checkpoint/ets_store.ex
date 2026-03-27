defmodule ADK.Workflow.Checkpoint.EtsStore do
  @moduledoc """
  ETS-backed checkpoint store for fast in-process workflow state persistence.

  Uses a named ETS table owned by this GenServer, so the table persists even
  when individual workflow executor processes die. Start in your supervision
  tree or use `init/0` for ad-hoc use in tests.

  ## Supervision

      children = [
        ADK.Workflow.Checkpoint.EtsStore,
        # ...
      ]

  Data is lost on VM restart (acceptable for development and short-lived
  workflows). For durable persistence, use `ADK.Workflow.Checkpoint.EctoStore`.
  """

  @behaviour ADK.Workflow.Checkpoint

  use GenServer

  @table_name :adk_workflow_checkpoints

  # ── GenServer API ──

  @doc "Start the ETS owner process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @impl GenServer
  @spec init(:ok) :: {:ok, %{table: :ets.table()}}
  def init(:ok) do
    table = :ets.new(@table_name, [:named_table, :public, :set, {:write_concurrency, true}, {:read_concurrency, true}])
    {:ok, %{table: table}}
  end

  @doc """
  Initialize the ETS table for standalone/test use (no GenServer).
  Idempotent and concurrent-safe.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table_name) == :undefined do
      # Ensure the table is created and owned by a persistent process
      case Process.whereis(__MODULE__) do
        nil ->
          # No GenServer running — start a temporary owner
          case GenServer.start_link(__MODULE__, :ok, name: __MODULE__) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _}} -> :ok
            {:error, _} -> ensure_raw_table()
          end

        _pid ->
          :ok
      end
    else
      :ok
    end
  end

  # ── Checkpoint Behaviour ──

  @impl ADK.Workflow.Checkpoint
  @spec save(String.t(), atom() | String.t(), atom(), any()) :: :ok
  def save(workflow_id, node_id, status, output) do
    ensure_table()
    checkpoint = ADK.Workflow.Checkpoint.new(workflow_id, node_id, status, output)
    :ets.insert(@table_name, {{workflow_id, node_id}, checkpoint})
    :ok
  rescue
    ArgumentError ->
      ensure_table()
      checkpoint = ADK.Workflow.Checkpoint.new(workflow_id, node_id, status, output)
      :ets.insert(@table_name, {{workflow_id, node_id}, checkpoint})
      :ok
  end

  @impl ADK.Workflow.Checkpoint
  @spec load(String.t(), atom() | String.t()) :: {:ok, map()} | :not_found
  def load(workflow_id, node_id) do
    ensure_table()

    case :ets.lookup(@table_name, {workflow_id, node_id}) do
      [{_, checkpoint}] -> {:ok, checkpoint}
      [] -> :not_found
    end
  end

  @impl ADK.Workflow.Checkpoint
  @spec load_all(String.t()) :: [map()]
  def load_all(workflow_id) do
    ensure_table()

    :ets.match_object(@table_name, {{workflow_id, :_}, :_})
    |> Enum.map(fn {_key, checkpoint} -> checkpoint end)
  end

  @impl ADK.Workflow.Checkpoint
  @spec completed_nodes(String.t()) :: [atom() | String.t()]
  def completed_nodes(workflow_id) do
    load_all(workflow_id)
    |> Enum.filter(fn cp -> cp.status == :completed end)
    |> Enum.map(fn cp -> cp.node_id end)
  end

  @impl ADK.Workflow.Checkpoint
  @spec clear(String.t()) :: :ok
  def clear(workflow_id) do
    ensure_table()
    :ets.match_delete(@table_name, {{workflow_id, :_}, :_})
    :ok
  end

  # ── Private ──

  defp ensure_table do
    if :ets.whereis(@table_name) == :undefined do
      init()
    end
  end

  defp ensure_raw_table do
    try do
      :ets.new(@table_name, [:named_table, :public, :set, {:write_concurrency, true}, {:read_concurrency, true}])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
