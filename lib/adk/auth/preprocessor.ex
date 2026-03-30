defmodule ADK.Auth.Preprocessor do
  @moduledoc """
  Pre-processes auth credential responses before an LLM request.

  Mirrors Python ADK's `_AuthLlmRequestProcessor`. This module:

  1. Scans session events for `adk_request_credential` function responses
     from the last user-authored event.
  2. Stores returned credentials via the credential service.
  3. Identifies original function calls that need to be resumed (the ones
     that requested auth in the first place).

  ## Usage

  Called by the runner's LLM request pipeline before sending the request
  to the model. If auth responses are found and processed, returns the set
  of original function call IDs to resume.

      case ADK.Auth.Preprocessor.process(events, credential_service) do
        {:resume, tool_ids} -> re-execute those tools
        :noop -> proceed normally
      end
  """

  alias ADK.Event

  @request_euc_function_call_name "adk_request_credential"
  @toolset_auth_prefix "_adk_toolset_auth_"

  @type process_result ::
          {:resume, MapSet.t(String.t())}
          | :noop

  @doc """
  Process session events for auth credential responses.

  Scans the given events list for the last user-authored event, looks for
  `adk_request_credential` function responses, stores credentials, and
  returns the set of original function call IDs that should be resumed.

  ## Parameters

    - `events` — list of `ADK.Event` structs (session history)
    - `agent` — the agent struct (must be an LlmAgent to proceed)
    - `opts` — keyword options:
      - `:credential_service` — module implementing `ADK.Auth.CredentialStore`
      - `:session_state` — session state map for credential storage

  ## Returns

    - `{:resume, tool_ids}` — set of function call IDs to re-execute
    - `:noop` — nothing to do (no auth responses found)
  """
  @spec process(list(Event.t()), struct(), keyword()) :: process_result()
  def process(events, agent, opts \\ [])

  def process(_events, agent, _opts) when not is_map(agent) do
    :noop
  end

  def process(events, agent, opts) do
    # Only proceed for LlmAgent (mirrors Python's isinstance check)
    unless is_llm_agent?(agent) do
      :noop
    else
      do_process(events, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Core Processing
  # ---------------------------------------------------------------------------

  defp do_process([], _opts), do: :noop

  defp do_process(events, opts) do
    # Find the last event with content
    case find_last_event_with_content(events) do
      nil ->
        :noop

      %{author: author} when author != "user" ->
        :noop

      last_user_event ->
        process_user_event(last_user_event, events, opts)
    end
  end

  defp process_user_event(user_event, events, opts) do
    responses = Event.function_responses(user_event)

    if responses == [] do
      :noop
    else
      process_auth_responses(responses, events, opts)
    end
  end

  defp process_auth_responses(responses, events, opts) do
    # Collect auth function response IDs and their response data
    {auth_fc_ids, auth_responses} =
      Enum.reduce(responses, {MapSet.new(), %{}}, fn response, {ids, resps} ->
        name = response["name"] || Map.get(response, :name)
        id = response["id"] || Map.get(response, :id)
        resp_data = response["response"] || Map.get(response, :response)

        if name == @request_euc_function_call_name do
          {MapSet.put(ids, id), Map.put(resps, id, resp_data)}
        else
          {ids, resps}
        end
      end)

    if MapSet.size(auth_fc_ids) == 0 do
      :noop
    else
      store_and_collect_resume_targets(events, auth_fc_ids, auth_responses, opts)
    end
  end

  @doc """
  Store auth credentials and collect function call IDs to resume.

  This is the core of the auth preprocessing pipeline:

  1. Scan events for `adk_request_credential` function calls matching
     the auth response IDs.
  2. Extract the `AuthToolArguments` from those calls to get the
     `credential_key` and `function_call_id`.
  3. Store credentials using the credential service.
  4. Return the set of original function call IDs to resume (excluding
     toolset auth entries).
  """
  @spec store_and_collect_resume_targets(
          list(Event.t()),
          MapSet.t(String.t()),
          map(),
          keyword()
        ) :: process_result()
  def store_and_collect_resume_targets(events, auth_fc_ids, auth_responses, opts) do
    credential_service = Keyword.get(opts, :credential_service)

    # Step 1: Find matching adk_request_credential function calls
    requested_configs = find_requested_auth_configs(events, auth_fc_ids)

    # Step 2: Store credentials
    store_credentials(auth_fc_ids, auth_responses, requested_configs, credential_service)

    # Step 3: Collect tool IDs to resume (excluding toolset auth)
    tools_to_resume = collect_tools_to_resume(events, auth_fc_ids)

    if MapSet.size(tools_to_resume) == 0 do
      :noop
    else
      {:resume, tools_to_resume}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_last_event_with_content(events) do
    events
    |> Enum.reverse()
    |> Enum.find(fn event -> event.content != nil end)
  end

  defp is_llm_agent?(%{__struct__: mod}) do
    mod_string = Atom.to_string(mod)
    String.contains?(mod_string, "LlmAgent")
  end

  defp is_llm_agent?(_), do: false

  @doc false
  def find_requested_auth_configs(events, auth_fc_ids) do
    Enum.reduce(events, %{}, fn event, acc ->
      calls = Event.function_calls(event)

      Enum.reduce(calls, acc, fn call, inner_acc ->
        call_id = call["id"] || Map.get(call, :id)
        call_name = call["name"] || Map.get(call, :name)

        if MapSet.member?(auth_fc_ids, call_id) &&
             call_name == @request_euc_function_call_name do
          args = call["args"] || Map.get(call, :args, %{})
          Map.put(inner_acc, call_id, args)
        else
          inner_acc
        end
      end)
    end)
  end

  defp store_credentials(auth_fc_ids, auth_responses, requested_configs, credential_service) do
    Enum.each(auth_fc_ids, fn fc_id ->
      auth_response = Map.get(auth_responses, fc_id)
      requested_config = Map.get(requested_configs, fc_id)

      if auth_response do
        # Merge credential_key from original request if available
        credential_key =
          case requested_config do
            %{"auth_config" => %{"credential_key" => key}} when is_binary(key) -> key
            %{auth_config: %{credential_key: key}} when is_binary(key) -> key
            _ -> nil
          end

        store_single_credential(auth_response, credential_key, credential_service)
      end
    end)
  end

  defp store_single_credential(auth_response, credential_key, credential_service) do
    # Build credential from auth response
    cred = extract_credential(auth_response)
    name = credential_key || extract_credential_key(auth_response)

    if credential_service && cred && name do
      credential_service.put(name, cred, [])
    end
  end

  defp extract_credential(%{__struct__: _} = auth_response) do
    # Struct — use dot access
    exchanged =
      if Map.has_key?(auth_response, :exchanged_credential),
        do: Map.get(auth_response, :exchanged_credential)

    raw =
      if Map.has_key?(auth_response, :raw_credential),
        do: Map.get(auth_response, :raw_credential)

    case exchanged || raw do
      %ADK.Auth.Credential{} = cred -> cred
      _ -> nil
    end
  end

  defp extract_credential(auth_response) when is_map(auth_response) do
    exchanged =
      auth_response["exchanged_auth_credential"] ||
        auth_response["exchanged_credential"]

    raw =
      auth_response["raw_auth_credential"] ||
        auth_response["raw_credential"]

    case exchanged || raw do
      %ADK.Auth.Credential{} = cred -> cred
      _ -> nil
    end
  end

  defp extract_credential(_), do: nil

  defp extract_credential_key(auth_response) when is_map(auth_response) do
    case auth_response do
      %{__struct__: _} -> Map.get(auth_response, :credential_key)
      _ -> auth_response["credential_key"] || Map.get(auth_response, :credential_key)
    end
  end

  defp extract_credential_key(_), do: nil

  defp collect_tools_to_resume(events, auth_fc_ids) do
    Enum.reduce(events, MapSet.new(), fn event, acc ->
      calls = Event.function_calls(event)

      Enum.reduce(calls, acc, fn call, inner_acc ->
        call_id = call["id"] || Map.get(call, :id)
        call_name = call["name"] || Map.get(call, :name)

        if MapSet.member?(auth_fc_ids, call_id) &&
             call_name == @request_euc_function_call_name do
          args = call["args"] || Map.get(call, :args, %{})

          function_call_id =
            args["function_call_id"] || Map.get(args, :function_call_id)

          if function_call_id && !String.starts_with?(function_call_id, @toolset_auth_prefix) do
            MapSet.put(inner_acc, function_call_id)
          else
            inner_acc
          end
        else
          inner_acc
        end
      end)
    end)
  end

  @doc """
  The canonical name for the request-credential function call.
  """
  @spec request_euc_function_call_name() :: String.t()
  def request_euc_function_call_name, do: @request_euc_function_call_name

  @doc """
  Prefix for toolset auth credential IDs (excluded from tool resumption).
  """
  @spec toolset_auth_prefix() :: String.t()
  def toolset_auth_prefix, do: @toolset_auth_prefix
end
