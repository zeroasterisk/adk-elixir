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
          plugins: [{module(), term()}],
          run_config: ADK.RunConfig.t() | nil,
          artifact_service: {module(), keyword()} | nil,
          credential_service: module() | nil,
          app_name: String.t() | nil,
          user_id: String.t() | nil,
          on_event: (ADK.Event.t() -> any()) | nil
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
    :on_event,
    temp_state: %{},
    ended: false,
    callbacks: [],
    policies: [],
    plugins: []
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

  @doc """
  Create a child context for a sub-agent.

  Extends the branch path to include the child agent name, enabling
  branch-aware content filtering. The branch uses dot-delimited paths
  like Python ADK's invocation_id hierarchy.
  """
  @spec for_child(t(), map()) :: t()
  def for_child(%__MODULE__{} = ctx, agent_spec) do
    child_name = ADK.Agent.name(agent_spec)
    child_branch = if ctx.branch, do: "#{ctx.branch}.#{child_name}", else: child_name
    %{ctx | agent: agent_spec, branch: child_branch, temp_state: %{}}
  end

  @doc """
  Emit an event via the streaming callback if one is set.

  Uses the process dictionary to deduplicate: if an event with the same ID was
  already emitted in this invocation, the call is a no-op. This allows both
  `LlmAgent` (which emits events inline during execution) and `Runner` (which
  emits at the end as a fallback) to call `emit_event` without double-firing.

  This is called internally by agents and the runner to stream events in real-time
  when an `on_event` callback is configured in the context.
  """
  @spec emit_event(t(), ADK.Event.t()) :: :ok
  def emit_event(%__MODULE__{} = ctx, event) do
    on_event_fn = ctx.on_event
    plugins = ctx.plugins || []
    inv_id = ctx.invocation_id

    # Fast path: nothing to do
    if is_nil(on_event_fn) and plugins == [] do
      :ok
    else
      # Track emitted event IDs per invocation in the process dictionary.
      # Events emitted by LlmAgent inline won't be re-fired by Runner.run fallback.
      pdict_key = {__MODULE__, :emitted, inv_id}
      emitted = Process.get(pdict_key, MapSet.new())
      event_id = event.id

      if is_nil(event_id) or not MapSet.member?(emitted, event_id) do
        unless is_nil(event_id) do
          Process.put(pdict_key, MapSet.put(emitted, event_id))
        end

        # Fire plugin on_event hooks
        ADK.Plugin.run_on_event(plugins, ctx, event)

        # Fire on_event streaming callback if set
        if is_function(on_event_fn, 1), do: on_event_fn.(event)
      end

      :ok
    end
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
