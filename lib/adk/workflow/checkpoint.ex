defmodule ADK.Workflow.Checkpoint do
  @moduledoc """
  Checkpoint behaviour for persisting workflow execution state.

  Enables save/resume of workflow progress. Two implementations:

  - `ADK.Workflow.Checkpoint.EtsStore` — fast in-process (default)
  - `ADK.Workflow.Checkpoint.EctoStore` — durable database persistence

  ## Checkpoint Data

  Each checkpoint captures:
  - `workflow_id` — unique execution identifier
  - `node_id` — the completed node
  - `status` — `:completed`, `:failed`, `:running`
  - `output` — node output data
  - `timestamp` — when the checkpoint was taken
  """

  @type node_id :: atom() | String.t()
  @type status :: :completed | :failed | :running

  @type checkpoint :: %{
          workflow_id: String.t(),
          node_id: node_id(),
          status: status(),
          output: any(),
          timestamp: DateTime.t()
        }

  @doc "Save a checkpoint for a completed node."
  @callback save(String.t(), node_id(), status(), any()) :: :ok | {:error, term()}

  @doc "Load checkpoint for a specific node."
  @callback load(String.t(), node_id()) :: {:ok, checkpoint()} | :not_found

  @doc "Load all checkpoints for a workflow execution."
  @callback load_all(String.t()) :: [checkpoint()]

  @doc "Get IDs of all completed nodes for a workflow."
  @callback completed_nodes(String.t()) :: [node_id()]

  @doc "Clear all checkpoints for a workflow execution."
  @callback clear(String.t()) :: :ok

  @doc """
  Create a checkpoint map.
  """
  @spec new(String.t(), node_id(), status(), any()) :: checkpoint()
  def new(workflow_id, node_id, status, output \\ nil) do
    %{
      workflow_id: workflow_id,
      node_id: node_id,
      status: status,
      output: output,
      timestamp: DateTime.utc_now()
    }
  end
end
