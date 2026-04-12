defmodule ADK.Memory.Store.VertexAI do
  @moduledoc """
  Vertex AI Agent Engine Memory Bank store implementation.

  Uses Google's Vertex AI Memory Bank REST API for persistent, semantic memory
  across sessions. Memory Bank scopes memories by `{agent_name, user_id}` and
  supports similarity search backed by embedding vectors.

  ## Configuration

      memory_service: {ADK.Memory.Store.VertexAI,
        project_id: "my-project",
        location: "us-central1",
        reasoning_engine_id: "1234567890"}

  ## Options

    * `:project_id` — GCP project ID (required)
    * `:location` — Region (default: `"us-central1"`)
    * `:reasoning_engine_id` — Vertex AI Reasoning Engine ID (required)
    * `:credentials_file` — Path to service account JSON
      (defaults to `GOOGLE_APPLICATION_CREDENTIALS` env var)
    * `:api_key` — API key (alternative to service account)
    * `:top_k` — Max results to return from similarity search (default: `10`)

  ## Memory format

  ADK `Memory.Entry` fields map to Vertex AI Memory Bank fields as follows:

    * `entry.id`       ← full Vertex AI memory resource name (returned from search)
    * `entry.content`  ↔ memory `fact`
    * `entry.author`   ↔ stored in scope under `"author"` key during `add/3`
    * `entry.timestamp` ← `create_time` returned by Vertex AI

  ## Auth

  Authentication follows the same pattern as `ADK.Artifact.GCS`:

  1. Service account JSON at `:credentials_file` option or
     `GOOGLE_APPLICATION_CREDENTIALS` env var.
  2. GCE/Cloud Run metadata server (automatic in Google-managed runtimes).

  ## API reference

  Endpoint base:
  `https://{location}-aiplatform.googleapis.com/v1beta1/projects/{project}/locations/{location}/reasoningEngines/{engine}/memories`

  Methods used:
  - `POST   .../memories`          — Create a memory
  - `POST   .../memories:retrieve` — Similarity search
  - `DELETE .../memories/{id}`     — Delete one memory
  - `GET    .../memories`          — List all (for clear)
  - `POST   .../memories:generate` — Generate from session events
  """

  @behaviour ADK.Memory.Store

  alias ADK.Memory.Entry

  @scopes ["https://www.googleapis.com/auth/cloud-platform"]
  @default_location "us-central1"
  @default_top_k 10

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Search memories using Vertex AI semantic similarity search.

  Maps `app_name` and `user_id` to Vertex AI scope keys.
  Returns entries sorted by relevance (lowest distance = most relevant).
  """
  @impl ADK.Memory.Store
  def search(app_name, user_id, query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    config = build_config(opts)

    body = %{
      scope: scope_for(app_name, user_id),
      similaritySearchParams: %{
        searchQuery: query,
        topK: top_k
      }
    }

    case request(:post, memories_url(config) <> ":retrieve", body, config) do
      {:ok, %{"memories" => memories}} ->
        entries =
          memories
          |> Enum.map(fn item ->
            memory = item["memory"] || item
            distance = item["distance"]
            entry_from_memory(memory, distance)
          end)

        {:ok, entries}

      {:ok, _} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Add memory entries to Vertex AI Memory Bank.

  Each `Entry.t()` becomes one Vertex AI memory. The `content` field is stored
  as the `fact`. The returned entry IDs (from `search/4`) will be the Vertex AI
  resource names, not the original ADK IDs.
  """
  @impl ADK.Memory.Store
  def add(app_name, user_id, entries) when is_list(entries) do
    with :ok <- validate_entries(entries) do
      config = build_config([])
      scope = scope_for(app_name, user_id)

      results =
        Enum.map(entries, fn entry ->
          body = %{
            fact: entry.content,
            scope: scope
          }

          request(:post, memories_url(config), body, config)
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))

      case errors do
        [] -> :ok
        [{:error, reason} | _] -> {:error, reason}
      end
    else
      {:error, _} = err -> err
    end
  end

  defp validate_entries([]) do
    {:error, :empty_entries}
  end

  defp validate_entries(entries) do
    Enum.reduce_while(entries, :ok, fn entry, _acc ->
      case entry.content do
        content when not is_binary(content) ->
          {:halt, {:error, :invalid_content_type}}

        content ->
          if String.trim(content) == "" do
            {:halt, {:error, :empty_content}}
          else
            {:cont, :ok}
          end
      end
    end)
  end

  @doc """
  Add memories from session events.

  Extracts text content from events and generates memories via the Vertex AI
  `memories:generate` endpoint using the `directMemoriesSource` format.
  Falls back to individual `add/3` if event extraction returns nothing.
  """
  @impl ADK.Memory.Store
  def add_session(app_name, user_id, _session_id, events) do
    config = build_config([])

    facts =
      events
      |> Enum.filter(&has_text_content?/1)
      |> Enum.map(&extract_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn text -> %{fact: text} end)

    if facts == [] do
      :ok
    else
      body = %{
        directMemoriesSource: %{directMemories: facts},
        scope: scope_for(app_name, user_id)
      }

      case request(:post, memories_url(config) <> ":generate", body, config) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Delete a specific memory by ID (Vertex AI resource name).

  The `entry_id` should be the full Vertex AI memory resource name returned
  from `search/4` (e.g. `projects/.../memories/abc123`), or just the memory ID
  suffix (e.g. `abc123`). If only a suffix is provided, the full resource name
  is constructed from configuration.
  """
  @impl ADK.Memory.Store
  def delete(app_name, user_id, entry_id) do
    config = build_config([])

    url =
      if String.contains?(entry_id, "/") do
        # Full resource name — use directly
        "https://#{config.location}-aiplatform.googleapis.com/v1beta1/#{entry_id}"
      else
        # Just the memory ID — build the full path
        memories_url(config) <> "/#{entry_id}"
      end

    case request(:delete, url, nil, config) do
      {:ok, _} -> :ok
      # Memory already gone — that's fine
      {:error, {:api_error, 404, _}} -> :ok
      {:error, _} = err -> err
    end
  rescue
    _ -> {:error, {:delete_failed, app_name, user_id, entry_id}}
  end

  @doc """
  Delete all memories for a user scope.

  Lists all memories for the scope, then deletes each one.
  """
  @impl ADK.Memory.Store
  def clear(app_name, user_id) do
    config = build_config([])
    scope = scope_for(app_name, user_id)

    # Build filter to list only memories for this scope
    # Vertex AI list endpoint supports filter param
    params = URI.encode_query(%{"filter" => build_scope_filter(scope)})
    list_url = memories_url(config) <> "?" <> params

    case request(:get, list_url, nil, config) do
      {:ok, %{"memories" => memories}} ->
        Enum.each(memories, fn memory ->
          name = memory["name"]

          if name do
            url = "https://#{config.location}-aiplatform.googleapis.com/v1beta1/#{name}"
            request(:delete, url, nil, config)
          end
        end)

        :ok

      {:ok, _} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp scope_for(app_name, user_id) do
    %{"agent_name" => app_name, "user_id" => user_id}
  end

  defp build_scope_filter(scope) do
    scope
    |> Enum.map(fn {k, v} -> ~s(scope.#{k}="#{v}") end)
    |> Enum.join(" AND ")
  end

  defp memories_url(config) do
    "https://#{config.location}-aiplatform.googleapis.com/v1beta1" <>
      "/projects/#{config.project_id}" <>
      "/locations/#{config.location}" <>
      "/reasoningEngines/#{config.reasoning_engine_id}" <>
      "/memories"
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

  # Use Req.Test plug when testing
  defp req_test_options do
    if ADK.Config.vertex_memory_test_plug() do
      [plug: {Req.Test, __MODULE__}]
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Auth (mirrors ADK.Artifact.GCS)
  # ---------------------------------------------------------------------------

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
         {:ok, creds} <- Jason.decode(json),
         {:ok, %{token: token}} <- ADK.Auth.Google.from_service_account_info(creds, @scopes) do
      {:ok, token}
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

  # ---------------------------------------------------------------------------
  # Mapping: Vertex AI memory → ADK Entry
  # ---------------------------------------------------------------------------

  defp entry_from_memory(memory, _distance) do
    name = memory["name"] || ""
    fact = memory["fact"] || ""

    timestamp =
      case memory["createTime"] do
        nil -> DateTime.utc_now()
        t -> parse_timestamp(t)
      end

    %Entry{
      id: name,
      content: fact,
      author: nil,
      metadata: %{
        "vertex_name" => name,
        "scope" => memory["scope"] || %{}
      },
      timestamp: timestamp
    }
  end

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # ---------------------------------------------------------------------------
  # Event helpers (for add_session/4)
  # ---------------------------------------------------------------------------

  defp has_text_content?(%ADK.Event{content: %{text: text}})
       when is_binary(text) and text != "",
       do: true

  defp has_text_content?(_), do: false

  defp extract_text(%ADK.Event{content: %{text: text}}), do: text
  defp extract_text(%ADK.Event{content: content}) when is_binary(content), do: content
  defp extract_text(_), do: ""
end
