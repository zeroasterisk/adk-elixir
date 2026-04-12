defmodule ADK.Session.Store.VertexAI do
  @moduledoc """
  Vertex AI Agent Engine Session Service store implementation.
  """

  @behaviour ADK.Session.Store

  @scopes ["https://www.googleapis.com/auth/cloud-platform"]
  @default_location "us-central1"

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl ADK.Session.Store
  def load(app_name, user_id, session_id) do
    config = build_config([])
    url = session_url(config, app_name, session_id)

    case request(:get, url, nil, config) do
      {:ok, session_data} ->
        if session_data["userId"] != user_id and session_data["user_id"] != user_id do
          {:error, {:forbidden, "Session #{session_id} does not belong to user #{user_id}."}}
        else
          # Fetch events
          events = fetch_all_events(config, app_name, session_id)
          state = session_data["sessionState"] || session_data["session_state"] || %{}

          {:ok,
           %{
             id: session_id,
             app_name: app_name,
             user_id: user_id,
             state: state,
             events: events
           }}
        end

      {:error, {:api_error, 404, _}} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  @impl ADK.Session.Store
  def save(%ADK.Session{} = session) do
    config = build_config([])
    url = session_url(config, session.app_name, session.id)

    # Fetch existing events to figure out what's new
    existing_events =
      case request(:get, url, nil, config) do
        {:ok, _} ->
          fetch_all_events(config, session.app_name, session.id)

        {:error, {:api_error, 404, _}} ->
          # Create session
          create_url = sessions_url(config, session.app_name) <> "?sessionId=#{session.id}"

          body = %{
            userId: session.user_id,
            sessionState: session.state || %{}
          }

          request(:post, create_url, body, config)
          []

        {:error, _} ->
          []
      end

    existing_invocations = MapSet.new(existing_events, & &1.invocation_id)

    # Append new events
    new_events =
      Enum.reject(session.events, &MapSet.member?(existing_invocations, &1.invocation_id))

    Enum.each(new_events, fn event ->
      append_url = url <> "/events:appendEvent"

      body = %{
        author: event.author,
        invocationId: event.invocation_id,
        timestamp: format_timestamp(event.timestamp),
        config: build_event_config(event)
      }

      request(:post, append_url, body, config)
    end)

    :ok
  end

  @impl ADK.Session.Store
  def delete(app_name, _user_id, session_id) do
    config = build_config([])
    url = session_url(config, app_name, session_id)

    case request(:delete, url, nil, config) do
      {:ok, _} -> :ok
      {:error, {:api_error, 404, _}} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl ADK.Session.Store
  def list(app_name, user_id) do
    config = build_config([])
    base_url = sessions_url(config, app_name)

    url =
      if user_id != nil and user_id != "" do
        base_url <> "?" <> URI.encode_query(%{"filter" => ~s(user_id="#{user_id}")})
      else
        base_url
      end

    case request(:get, url, nil, config) do
      {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
        Enum.map(sessions, fn s ->
          s["name"] |> String.split("/") |> List.last()
        end)

      {:ok, _} ->
        []

      {:error, _} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_all_events(config, app_name, session_id, page_token \\ nil, acc \\ []) do
    url = session_url(config, app_name, session_id) <> "/events"

    url =
      if page_token, do: url <> "?" <> URI.encode_query(%{"pageToken" => page_token}), else: url

    case request(:get, url, nil, config) do
      {:ok, %{"events" => events_page} = resp} when is_list(events_page) ->
        parsed = Enum.map(events_page, &parse_event/1)
        acc = acc ++ parsed

        case resp["nextPageToken"] do
          token when is_binary(token) and token != "" ->
            fetch_all_events(config, app_name, session_id, token, acc)

          _ ->
            acc
        end

      _ ->
        acc
    end
  end

  defp parse_event(api_event) do
    # API fields: name, invocation_id, author, timestamp, content, actions, event_metadata
    id = api_event["name"] |> String.split("/") |> List.last()

    actions_map = api_event["actions"] || %{}

    event_metadata = api_event["event_metadata"] || api_event["eventMetadata"] || %{}
    custom_metadata = event_metadata["custom_metadata"] || event_metadata["customMetadata"] || %{}

    # Extract compaction from custom_metadata (mirrors python workaround)
    {compaction_map, custom_metadata} = Map.pop(custom_metadata, "_compaction")

    custom_metadata = if custom_metadata == %{}, do: nil, else: custom_metadata

    compaction = if compaction_map, do: ADK.EventCompaction.from_map(compaction_map), else: nil

    actions = %ADK.EventActions{
      state_delta: actions_map["state_delta"] || actions_map["stateDelta"] || %{},
      transfer_to_agent:
        actions_map["transfer_agent"] || actions_map["transferAgent"] ||
          actions_map["transfer_to_agent"],
      escalate: actions_map["escalate"] || false,
      compaction: compaction
    }

    %ADK.Event{
      id: id,
      invocation_id: api_event["invocation_id"] || api_event["invocationId"],
      author: api_event["author"],
      timestamp: parse_timestamp(api_event["timestamp"]),
      content: api_event["content"],
      actions: actions,
      custom_metadata: custom_metadata,
      partial: event_metadata["partial"] || false,
      branch: event_metadata["branch"],
      error: api_event["error_message"] || api_event["errorMessage"]
    }
  end

  defp build_event_config(event) do
    config = %{}

    config = if event.content, do: Map.put(config, "content", event.content), else: config

    actions = %{}

    actions =
      if event.actions.state_delta != %{},
        do: Map.put(actions, "state_delta", event.actions.state_delta),
        else: actions

    actions =
      if event.actions.transfer_to_agent,
        do: Map.put(actions, "transfer_agent", event.actions.transfer_to_agent),
        else: actions

    actions =
      if event.actions.escalate,
        do: Map.put(actions, "escalate", event.actions.escalate),
        else: actions

    config = if actions != %{}, do: Map.put(config, "actions", actions), else: config

    config =
      if event.error, do: Map.put(config, "error_message", to_string(event.error)), else: config

    meta = %{}
    meta = if event.partial, do: Map.put(meta, "partial", event.partial), else: meta
    meta = if event.branch, do: Map.put(meta, "branch", event.branch), else: meta

    custom = event.custom_metadata || %{}

    custom =
      if event.actions.compaction,
        do: Map.put(custom, "_compaction", struct_to_map(event.actions.compaction)),
        else: custom

    meta = if custom != %{}, do: Map.put(meta, "custom_metadata", custom), else: meta

    config = if meta != %{}, do: Map.put(config, "event_metadata", meta), else: config
    config
  end

  defp struct_to_map(struct) when is_struct(struct),
    do: Map.from_struct(struct) |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  defp struct_to_map(map) when is_map(map), do: map
  defp struct_to_map(other), do: other

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp sessions_url(config, app_name) do
    engine_id = reasoning_engine_id(config, app_name)

    "https://#{config.location}-aiplatform.googleapis.com/v1beta1" <>
      "/projects/#{config.project_id}" <>
      "/locations/#{config.location}" <>
      "/reasoningEngines/#{engine_id}/sessions"
  end

  defp session_url(config, app_name, session_id) do
    sessions_url(config, app_name) <> "/#{session_id}"
  end

  defp reasoning_engine_id(config, app_name) do
    # Mirrors Python's `_get_reasoning_engine_id` logic
    cond do
      config.reasoning_engine_id ->
        config.reasoning_engine_id

      String.match?(app_name, ~r/^\d+$/) ->
        app_name

      String.match?(app_name, ~r/^projects\/.*\/locations\/.*\/reasoningEngines\/(\d+)$/) ->
        [_, id] = Regex.run(~r/^projects\/.*\/locations\/.*\/reasoningEngines\/(\d+)$/, app_name)
        id

      true ->
        app_name
    end
  end

  defp build_config(opts) do
    %{
      project_id:
        Keyword.get(opts, :project_id) ||
          ADK.Config.vertex_project_id() ||
          System.get_env("GOOGLE_CLOUD_PROJECT") ||
          System.get_env("GCLOUD_PROJECT"),
      location:
        Keyword.get(opts, :location) ||
          ADK.Config.vertex_location() ||
          @default_location,
      reasoning_engine_id:
        Keyword.get(opts, :reasoning_engine_id) ||
          ADK.Config.vertex_reasoning_engine_id(),
      credentials_file:
        Keyword.get(opts, :credentials_file) ||
          ADK.Config.vertex_credentials_file() ||
          System.get_env("GOOGLE_APPLICATION_CREDENTIALS"),
      api_key:
        Keyword.get(opts, :api_key) ||
          ADK.Config.vertex_api_key()
    }
  end

  defp request(method, url, body, config) do
    with {:ok, token} <- get_access_token(config) do
      auth_headers = [{"authorization", "Bearer #{token}"}]

      req_opts =
        [url: url, headers: auth_headers, retry: false] ++
          if(body, do: [json: body], else: []) ++
          req_test_options()

      result =
        case method do
          :post -> Req.post(req_opts)
          :get -> Req.get(req_opts)
          :delete -> Req.delete(req_opts)
        end

      case result do
        {:ok, %{status: s, body: b}} when s in 200..299 ->
          {:ok, b}

        {:ok, %{status: 404, body: b}} ->
          {:error, {:api_error, 404, b}}

        {:ok, %{status: s, body: b}} ->
          {:error, {:api_error, s, b}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp req_test_options do
    if ADK.Config.vertex_session_test_plug() do
      [plug: {Req.Test, __MODULE__}]
    else
      []
    end
  end

  defp get_access_token(%{api_key: api_key}) when is_binary(api_key) and api_key != "" do
    {:ok, api_key}
  end

  defp get_access_token(%{credentials_file: creds_file} = _config) do
    cond do
      creds_file && File.exists?(creds_file) ->
        get_sa_token(creds_file)

      true ->
        get_metadata_token()
    end
  end

  defp get_sa_token(creds_file) do
    with {:ok, json} <- File.read(creds_file),
         {:ok, creds} <- Jason.decode(json) do
      now = System.system_time(:second)

      header =
        Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)

      claims =
        Base.url_encode64(
          Jason.encode!(%{
            "iss" => creds["client_email"],
            "scope" => Enum.join(@scopes, " "),
            "aud" => "https://oauth2.googleapis.com/token",
            "iat" => now,
            "exp" => now + 3600
          }),
          padding: false
        )

      signing_input = "#{header}.#{claims}"

      [entry] = :public_key.pem_decode(creds["private_key"])
      key = :public_key.pem_entry_decode(entry)
      signature = :public_key.sign(signing_input, :sha256, key)
      sig_b64 = Base.url_encode64(signature, padding: false)

      jwt = "#{signing_input}.#{sig_b64}"

      resp =
        Req.post!("https://oauth2.googleapis.com/token",
          form: [
            grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
            assertion: jwt
          ]
        )

      case resp.status do
        200 -> {:ok, resp.body["access_token"]}
        s -> {:error, {:token_error, s, resp.body}}
      end
    end
  end

  defp get_metadata_token do
    resp =
      Req.get!(
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
        headers: [{"metadata-flavor", "Google"}]
      )

    case resp.status do
      200 -> {:ok, resp.body["access_token"]}
      s -> {:error, {:metadata_token_error, s}}
    end
  rescue
    _ -> {:error, :no_credentials}
  end
end
