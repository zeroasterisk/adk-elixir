defmodule ADK.Context do
  @moduledoc "Invocation context threaded through the agent pipeline."

  @type t :: %__MODULE__{
          invocation_id: String.t(),
          session_pid: pid() | nil,
          agent: any(),
          branch: String.t() | nil,
          user_content: map() | nil,
          temp_state: map(),
          ended: boolean(),
          callbacks: [module()],
          policies: [module()],
          run_config: ADK.RunConfig.t() | nil,
          artifact_service: {module(), keyword()} | nil,
          credential_service: module() | nil,
          app_name: String.t() | nil,
          user_id: String.t() | nil
        }

  defstruct [
    :invocation_id,
    :session_pid,
    :agent,
    :branch,
    :user_content,
    :run_config,
    :artifact_service,
    :credential_service,
    :memory_store,
    :app_name,
    :user_id,
    temp_state: %{},
    ended: false,
    callbacks: [],
    policies: []
  ]

  @doc """
  Fork context for a parallel branch.

  ## Examples

      iex> ctx = %ADK.Context{invocation_id: "inv-1", branch: nil}
      iex> child = ADK.Context.fork_branch(ctx, "searcher")
      iex> child.branch
      "searcher"
  """
  @spec fork_branch(t(), String.t()) :: t()
  def fork_branch(%__MODULE__{branch: parent} = ctx, child_name) do
    branch = if parent, do: "#{parent}.#{child_name}", else: child_name
    %{ctx | branch: branch, temp_state: %{}}
  end

  @doc "Create a child context for a sub-agent."
  @spec for_child(t(), map()) :: t()
  def for_child(%__MODULE__{} = ctx, agent_spec) do
    %{ctx | agent: agent_spec, temp_state: %{}}
  end

  @doc "Get a value from temp state."
  @spec get_temp(t(), term()) :: term() | nil
  def get_temp(%__MODULE__{temp_state: ts}, key), do: Map.get(ts, key)

  @doc "Put a value in temp state, returning updated context."
  @spec put_temp(t(), term(), term()) :: t()
  def put_temp(%__MODULE__{} = ctx, key, value) do
    %{ctx | temp_state: Map.put(ctx.temp_state, key, value)}
  end
end
