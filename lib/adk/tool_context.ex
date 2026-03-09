defmodule ADK.ToolContext do
  @moduledoc """
  Context passed to tool execution, wrapping the invocation context.

  Provides session state read/write, artifact get/set (stubbed),
  agent transfer capability, and auth/credential access (stubbed).
  """

  @type t :: %__MODULE__{
          context: ADK.Context.t(),
          function_call_id: String.t(),
          tool_name: String.t(),
          tool_def: map() | nil
        }

  defstruct [:context, :function_call_id, :tool_name, :tool_def]

  @doc "Create a tool context from an invocation context."
  @spec new(ADK.Context.t(), String.t(), map() | module()) :: t()
  def new(%ADK.Context{} = ctx, call_id, tool) do
    %__MODULE__{
      context: ctx,
      function_call_id: call_id,
      tool_name: tool_name(tool),
      tool_def: tool
    }
  end

  # --- Session State ---

  @doc "Read a value from session state."
  @spec get_state(t(), term(), term()) :: term()
  def get_state(%__MODULE__{context: ctx}, key, default \\ nil) do
    if ctx.session_pid do
      ADK.Session.get_state(ctx.session_pid, key) || default
    else
      default
    end
  end

  @doc "Write a value to session state."
  @spec put_state(t(), term(), term()) :: :ok | {:error, :no_session}
  def put_state(%__MODULE__{context: ctx}, key, value) do
    if ctx.session_pid do
      ADK.Session.put_state(ctx.session_pid, key, value)
    else
      {:error, :no_session}
    end
  end

  # --- Artifacts (stubbed) ---

  @doc "Get an artifact by key. Returns `{:error, :not_implemented}` until an artifact service is configured."
  @spec get_artifact(t(), String.t()) :: {:ok, term()} | {:error, :not_implemented}
  def get_artifact(%__MODULE__{}, _key) do
    {:error, :not_implemented}
  end

  @doc "Set an artifact by key. Returns `{:error, :not_implemented}` until an artifact service is configured."
  @spec set_artifact(t(), String.t(), term()) :: :ok | {:error, :not_implemented}
  def set_artifact(%__MODULE__{}, _key, _value) do
    {:error, :not_implemented}
  end

  # --- Agent Transfer ---

  @doc """
  Request transfer to another agent by name.

  Returns an event with a transfer action that the runner will handle.
  """
  @spec transfer_to_agent(t(), String.t()) :: ADK.Event.t()
  def transfer_to_agent(%__MODULE__{context: ctx, tool_name: tool_name}, target_agent) do
    ADK.Event.new(%{
      invocation_id: ctx.invocation_id,
      author: tool_name,
      content: %{parts: [%{text: "Transferring to #{target_agent}"}]},
      actions: %ADK.EventActions{transfer_to_agent: target_agent}
    })
  end

  # --- Auth / Credentials (stubbed) ---

  @doc "Get a credential by key. Returns `{:error, :not_implemented}` until a credential service is configured."
  @spec get_credential(t(), String.t()) :: {:ok, term()} | {:error, :not_implemented}
  def get_credential(%__MODULE__{}, _key) do
    {:error, :not_implemented}
  end

  @doc "Check if a credential exists. Returns `false` until a credential service is configured."
  @spec has_credential?(t(), String.t()) :: boolean()
  def has_credential?(%__MODULE__{}, _key) do
    false
  end

  defp tool_name(%{name: n}), do: n
  defp tool_name(m) when is_atom(m), do: m.name()
end
