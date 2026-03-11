defmodule ADK.ToolContext do
  @moduledoc """
  Context passed to tool execution, providing access to session state,
  artifacts, credentials, and agent transfer capabilities.

  Mirrors Python ADK's unified `Context` (formerly `ToolContext`) — tools
  receive this struct and use its functions to interact with the runtime.

  ## Capabilities

  - **Session state** — `get_state/3`, `put_state/3` for reading/writing session state
  - **Artifacts** — `save_artifact/4`, `load_artifact/3`, `list_artifacts/1` for file/blob storage
  - **Credentials** — `request_credential/2`, `load_credential/2`, `save_credential/2`
  - **Agent transfer** — `transfer_to_agent/2` to hand off to another agent
  - **Event actions** — `actions/1` to access the mutable event actions (state/artifact deltas)
  """

  alias ADK.EventActions

  @type t :: %__MODULE__{
          context: ADK.Context.t(),
          function_call_id: String.t(),
          tool_name: String.t(),
          tool_def: map() | nil,
          actions: EventActions.t()
        }

  defstruct [:context, :function_call_id, :tool_name, :tool_def, actions: %EventActions{}]

  @doc "Create a tool context from an invocation context."
  @spec new(ADK.Context.t(), String.t(), map() | module()) :: t()
  def new(%ADK.Context{} = ctx, call_id, tool) do
    %__MODULE__{
      context: ctx,
      function_call_id: call_id,
      tool_name: tool_name(tool),
      tool_def: tool,
      actions: %EventActions{}
    }
  end

  @doc "Get the event actions (state deltas, artifact deltas, auth requests)."
  @spec actions(t()) :: EventActions.t()
  def actions(%__MODULE__{actions: actions}), do: actions

  # ---------------------------------------------------------------------------
  # Session State
  # ---------------------------------------------------------------------------

  @doc "Read a value from session state."
  @spec get_state(t(), term(), term()) :: term()
  def get_state(%__MODULE__{context: ctx}, key, default \\ nil) do
    if ctx.session_pid do
      ADK.Session.get_state(ctx.session_pid, key) || default
    else
      default
    end
  end

  @doc "Write a value to session state and track the delta."
  @spec put_state(t(), term(), term()) :: {:ok, t()} | {:error, :no_session}
  def put_state(%__MODULE__{context: ctx, actions: actions} = tc, key, value) do
    if ctx.session_pid do
      ADK.Session.put_state(ctx.session_pid, key, value)
      updated_actions = %{actions | state_delta: Map.put(actions.state_delta, key, value)}
      {:ok, %{tc | actions: updated_actions}}
    else
      {:error, :no_session}
    end
  end

  # ---------------------------------------------------------------------------
  # Artifacts
  # ---------------------------------------------------------------------------

  @doc """
  Save an artifact and track the version in event actions.

  Returns `{:ok, version, updated_context}` on success.
  Returns `{:error, :no_artifact_service}` if no artifact service is configured.
  """
  @spec save_artifact(t(), String.t(), map(), keyword()) ::
          {:ok, non_neg_integer(), t()} | {:error, term()}
  def save_artifact(%__MODULE__{context: ctx, actions: actions} = tc, filename, artifact, opts \\ []) do
    case ctx.artifact_service do
      nil ->
        {:error, :no_artifact_service}

      service_config ->
        {service, backend_opts} = normalize_service(service_config)
        session_id = get_session_id(ctx)
        merged_opts = Keyword.merge(backend_opts, opts)

        case service.save(
               ctx.app_name || "default",
               ctx.user_id || "default",
               session_id,
               filename,
               artifact,
               merged_opts
             ) do
          {:ok, version} ->
            updated_actions = %{actions | artifact_delta: Map.put(actions.artifact_delta, filename, version)}
            {:ok, version, %{tc | actions: updated_actions}}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Load an artifact by filename.

  Options:
  - `:version` — specific version to load (default: latest)
  """
  @spec load_artifact(t(), String.t(), keyword()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def load_artifact(%__MODULE__{context: ctx}, filename, opts \\ []) do
    case ctx.artifact_service do
      nil -> {:error, :no_artifact_service}
      service_config ->
        {service, backend_opts} = normalize_service(service_config)
        session_id = get_session_id(ctx)
        service.load(
          ctx.app_name || "default",
          ctx.user_id || "default",
          session_id,
          filename,
          Keyword.merge(backend_opts, opts)
        )
    end
  end

  @doc "List artifact filenames for the current session."
  @spec list_artifacts(t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_artifacts(%__MODULE__{context: ctx}) do
    case ctx.artifact_service do
      nil -> {:error, :no_artifact_service}
      service_config ->
        {service, backend_opts} = normalize_service(service_config)
        session_id = get_session_id(ctx)
        service.list(
          ctx.app_name || "default",
          ctx.user_id || "default",
          session_id,
          backend_opts
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Credentials
  # ---------------------------------------------------------------------------

  @doc """
  Request a credential for the current tool call.

  This records the auth config in event actions so the runner can surface
  an auth challenge to the user/client. Only works in tool context
  (requires `function_call_id`).
  """
  @spec request_credential(t(), ADK.Auth.Config.t()) :: {:ok, t()} | {:error, term()}
  def request_credential(%__MODULE__{function_call_id: nil}, _auth_config) do
    {:error, :no_function_call_id}
  end

  def request_credential(%__MODULE__{function_call_id: call_id, actions: actions} = tc, auth_config) do
    updated_actions = %{
      actions
      | requested_auth_configs: Map.put(actions.requested_auth_configs, call_id, auth_config)
    }

    {:ok, %{tc | actions: updated_actions}}
  end

  @doc """
  Load a credential from the credential service.

  Returns `{:ok, credential}` or `:not_found` or `{:error, reason}`.
  """
  @spec load_credential(t(), String.t()) ::
          {:ok, ADK.Auth.Credential.t()} | :not_found | {:error, term()}
  def load_credential(%__MODULE__{context: ctx}, credential_name) do
    case ctx.credential_service do
      nil -> {:error, :no_credential_service}
      service -> service.get(credential_name, [])
    end
  end

  @doc """
  Save a credential to the credential service.
  """
  @spec save_credential(t(), String.t(), ADK.Auth.Credential.t()) :: :ok | {:error, term()}
  def save_credential(%__MODULE__{context: ctx}, credential_name, credential) do
    case ctx.credential_service do
      nil -> {:error, :no_credential_service}
      service -> service.put(credential_name, credential, [])
    end
  end

  @doc "Check if a credential exists in the credential service."
  @spec has_credential?(t(), String.t()) :: boolean()
  def has_credential?(%__MODULE__{} = tc, credential_name) do
    case load_credential(tc, credential_name) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Agent Transfer
  # ---------------------------------------------------------------------------

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
      actions: %EventActions{transfer_to_agent: target_agent}
    })
  end

  # ---------------------------------------------------------------------------
  # Legacy API (backward compatibility)
  # ---------------------------------------------------------------------------

  @doc false
  @deprecated "Use load_artifact/3 instead"
  def get_artifact(%__MODULE__{} = tc, key), do: load_artifact(tc, key)

  @doc false
  @deprecated "Use save_artifact/4 instead"
  def set_artifact(%__MODULE__{} = tc, key, value) do
    case save_artifact(tc, key, %{data: value, content_type: "application/octet-stream", metadata: %{}}) do
      {:ok, _version, _tc} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc false
  @deprecated "Use load_credential/2 instead"
  def get_credential(%__MODULE__{} = tc, key), do: load_credential(tc, key)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp normalize_service({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  defp normalize_service(mod) when is_atom(mod), do: {mod, []}

  defp tool_name(%{name: n}), do: n
  defp tool_name(m) when is_atom(m), do: m.name()

  defp get_session_id(%{session_pid: nil}), do: "unknown"
  defp get_session_id(%{session_pid: pid}) do
    case ADK.Session.get(pid) do
      {:ok, session} -> session.id || "unknown"
      _ -> "unknown"
    end
  end
end
