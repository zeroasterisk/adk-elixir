# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Models.GeminiContextCacheManager do
  @moduledoc """
  Manages context cache lifecycle for Gemini models.

  This module handles cache creation, validation, cleanup, and metadata
  population for Gemini context caching. It uses content hashing to determine
  cache compatibility and implements efficient caching strategies.

  ## Manager struct

  The manager holds a reference to a client module that implements cache
  operations. In production this would be the Gemini API client; in tests
  it can be a mock.

  The client module must implement:
    * `create_cache(model, config)` — creates a cached content, returns `{:ok, %{name: ...}}` or `{:error, reason}`
    * `delete_cache(name)` — deletes a cached content, returns `:ok` or `{:error, reason}`
  """

  alias ADK.Models.CacheMetadata

  require Logger

  defstruct [:client]

  @type t :: %__MODULE__{
          client: module() | map()
        }

  @doc """
  Creates a new cache manager with the given client.
  """
  @spec new(module() | map()) :: t()
  def new(client) do
    %__MODULE__{client: client}
  end

  @doc """
  Handle context caching for Gemini models.

  Validates existing cache or creates a new one if needed. Returns cache
  metadata to be included in the response.

  ## Parameters

    * `manager` — the cache manager struct
    * `llm_request` — map with keys: `:contents`, `:config`, `:cache_config`,
      `:cache_metadata`, `:model`, `:cacheable_contents_token_count`

  ## Returns

  Cache metadata struct, or `nil` if caching failed.
  """
  @spec handle_context_caching(t(), map()) :: CacheMetadata.t() | nil
  def handle_context_caching(manager, llm_request) do
    case Map.get(llm_request, :cache_metadata) do
      nil ->
        # No existing cache metadata — return fingerprint-only
        Logger.debug("No existing cache metadata, creating fingerprint-only metadata")
        total = length(Map.get(llm_request, :contents, []))
        fp = generate_cache_fingerprint(llm_request, total)
        CacheMetadata.fingerprint_only(fp, total)

      existing ->
        Logger.debug("Found existing cache metadata: #{existing}")

        if is_cache_valid(llm_request) do
          # Valid cache — reuse it
          Logger.debug("Cache is valid, reusing: #{existing.cache_name}")
          apply_cache_to_request(llm_request, existing.cache_name, existing.contents_count)
          # Return a copy (structs are immutable in Elixir, so this is already a copy)
          copy_metadata(existing)
        else
          # Invalid cache — clean up and maybe create new
          handle_invalid_cache(manager, llm_request, existing)
        end
    end
  end

  defp handle_invalid_cache(manager, llm_request, old_metadata) do
    # Only cleanup if there's an active cache
    if old_metadata.cache_name != nil do
      Logger.debug("Cache is invalid, cleaning up: #{old_metadata.cache_name}")
      cleanup_cache(manager, old_metadata.cache_name)
    end

    cache_contents_count = old_metadata.contents_count
    current_fp = generate_cache_fingerprint(llm_request, cache_contents_count)

    if current_fp == old_metadata.fingerprint do
      # Fingerprints match — create new cache (expired but same content)
      Logger.debug("Fingerprints match after invalidation, creating new cache")

      case create_new_cache_with_contents(manager, llm_request, cache_contents_count) do
        {:ok, new_metadata} ->
          apply_cache_to_request(llm_request, new_metadata.cache_name, cache_contents_count)
          new_metadata

        _ ->
          # Fall back to fingerprint-only
          CacheMetadata.fingerprint_only(current_fp, cache_contents_count)
      end
    else
      # Fingerprints don't match — return fingerprint-only with total contents
      Logger.debug("Fingerprints don't match, returning fingerprint-only metadata")
      total = length(Map.get(llm_request, :contents, []))
      fp = generate_cache_fingerprint(llm_request, total)
      CacheMetadata.fingerprint_only(fp, total)
    end
  end

  @doc """
  Check if the cache from request metadata is still valid.

  Validates that it's an active cache (not fingerprint-only), checks expiry,
  cache intervals, and fingerprint compatibility.
  """
  @spec is_cache_valid(map()) :: boolean()
  def is_cache_valid(llm_request) do
    meta = Map.get(llm_request, :cache_metadata)

    cache_config = Map.get(llm_request, :cache_config)

    cond do
      meta == nil ->
        false

      # Fingerprint-only metadata is not a valid active cache
      meta.cache_name == nil ->
        false

      # Check if cache has expired
      now() >= meta.expire_time ->
        Logger.info("Cache expired: #{meta.cache_name}")
        false

      # Check if cache intervals exceeded
      meta.invocations_used > cache_config.cache_intervals ->
        Logger.info(
          "Cache exceeded intervals: #{meta.cache_name} (#{meta.invocations_used} > #{cache_config.cache_intervals})"
        )

        false

      # Check fingerprint match
      true ->
        current_fp = generate_cache_fingerprint(llm_request, meta.contents_count)

        if current_fp != meta.fingerprint do
          Logger.debug("Cache content fingerprint mismatch")
          false
        else
          true
        end
    end
  end

  @doc """
  Generate a fingerprint for cache validation.

  Includes system instruction, tools, tool_config, and first N contents.
  Returns a 16-character hexadecimal fingerprint.
  """
  @spec generate_cache_fingerprint(map(), non_neg_integer()) :: String.t()
  def generate_cache_fingerprint(llm_request, cache_contents_count) do
    config = Map.get(llm_request, :config, %{})
    data = %{}

    data =
      case get_nested(config, :system_instruction) do
        nil -> data
        si -> Map.put(data, :system_instruction, si)
      end

    data =
      case get_nested(config, :tools) do
        nil -> data
        tools -> Map.put(data, :tools, tools)
      end

    data =
      case get_nested(config, :tool_config) do
        nil -> data
        tc -> Map.put(data, :tool_config, tc)
      end

    data =
      if cache_contents_count > 0 do
        contents = Map.get(llm_request, :contents, [])
        cached = Enum.take(contents, cache_contents_count)

        if cached != [] do
          Map.put(data, :cached_contents, cached)
        else
          data
        end
      else
        data
      end

    fingerprint_str = inspect(data, limit: :infinity, printable_limit: :infinity)

    :crypto.hash(:sha256, fingerprint_str)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  @doc """
  Clean up cache by deleting it via the client.
  """
  @spec cleanup_cache(t(), String.t()) :: :ok
  def cleanup_cache(%__MODULE__{client: client}, cache_name) do
    Logger.debug("Attempting to delete cache: #{cache_name}")

    try do
      client.delete_cache(cache_name)
      Logger.info("Cache cleaned up: #{cache_name}")
      :ok
    rescue
      e ->
        Logger.warning("Failed to cleanup cache #{cache_name}: #{inspect(e)}")
        :ok
    end
  end

  @doc """
  Apply cache to the request by modifying it to use cached content.

  Returns the modified request map with:
  - system_instruction, tools, tool_config removed from config
  - cached_content set in config
  - cached contents removed from contents list
  """
  @spec apply_cache_to_request(map(), String.t(), non_neg_integer()) :: map()
  def apply_cache_to_request(llm_request, cache_name, cache_contents_count) do
    config =
      (Map.get(llm_request, :config) || %{})
      |> remove_key(:system_instruction)
      |> remove_key(:tools)
      |> remove_key(:tool_config)
      |> Map.put(:cached_content, cache_name)

    contents = Map.get(llm_request, :contents, [])
    remaining_contents = Enum.drop(contents, cache_contents_count)

    llm_request
    |> Map.put(:config, config)
    |> Map.put(:contents, remaining_contents)
  end

  @doc """
  Populate cache metadata in LLM response.

  Copies the cache metadata into the response map.
  """
  @spec populate_cache_metadata_in_response(map(), CacheMetadata.t()) :: map()
  def populate_cache_metadata_in_response(llm_response, cache_metadata) do
    Map.put(llm_response, :cache_metadata, copy_metadata(cache_metadata))
  end

  @doc """
  Create a new cache via the API client.
  """
  @spec create_gemini_cache(t(), map(), non_neg_integer()) ::
          {:ok, CacheMetadata.t()} | {:error, term()}
  def create_gemini_cache(%__MODULE__{client: client}, llm_request, cache_contents_count) do
    contents = Map.get(llm_request, :contents, [])
    cache_contents = Enum.take(contents, cache_contents_count)
    cache_config = Map.get(llm_request, :cache_config)
    config = Map.get(llm_request, :config, %{})

    create_config = %{
      contents: cache_contents,
      ttl: ADK.Agents.ContextCacheConfig.ttl_string(cache_config),
      display_name: "adk-cache-#{trunc(now())}-#{cache_contents_count}contents"
    }

    create_config =
      case get_nested(config, :system_instruction) do
        nil -> create_config
        si -> Map.put(create_config, :system_instruction, si)
      end

    create_config =
      case get_nested(config, :tools) do
        nil -> create_config
        tools -> Map.put(create_config, :tools, tools)
      end

    create_config =
      case get_nested(config, :tool_config) do
        nil -> create_config
        tc -> Map.put(create_config, :tool_config, tc)
      end

    model = Map.get(llm_request, :model)

    case client.create_cache(model, create_config) do
      {:ok, cached_content} ->
        created_at = now()

        metadata =
          CacheMetadata.new(
            cache_name: cached_content.name,
            expire_time: created_at + cache_config.ttl_seconds,
            fingerprint: generate_cache_fingerprint(llm_request, cache_contents_count),
            invocations_used: 1,
            contents_count: cache_contents_count,
            created_at: created_at
          )

        {:ok, metadata}

      {:error, reason} ->
        Logger.warning("Failed to create cache: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Private helpers --

  defp create_new_cache_with_contents(manager, llm_request, cache_contents_count) do
    token_count = Map.get(llm_request, :cacheable_contents_token_count)
    cache_config = Map.get(llm_request, :cache_config)

    cond do
      token_count == nil ->
        Logger.info("No previous token count available, skipping cache creation")
        {:error, :no_token_count}

      cache_config != nil and token_count < cache_config.min_tokens ->
        Logger.info(
          "Previous request too small for caching (#{token_count} < #{cache_config.min_tokens} tokens)"
        )

        {:error, :too_small}

      true ->
        create_gemini_cache(manager, llm_request, cache_contents_count)
    end
  end

  defp copy_metadata(%CacheMetadata{} = meta) do
    # Structs are immutable in Elixir, returning same struct is effectively a copy
    %CacheMetadata{
      cache_name: meta.cache_name,
      expire_time: meta.expire_time,
      fingerprint: meta.fingerprint,
      invocations_used: meta.invocations_used,
      contents_count: meta.contents_count,
      created_at: meta.created_at
    }
  end

  defp get_nested(nil, _key), do: nil
  defp get_nested(map, key) when is_map(map), do: Map.get(map, key)
  defp get_nested(struct, key), do: Map.get(struct, key, nil)

  defp remove_key(map, key) when is_map(map), do: Map.delete(map, key)

  defp now do
    :os.system_time(:second) + 0.0
  end
end
