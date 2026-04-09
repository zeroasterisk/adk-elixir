defmodule ADK.Models.GeminiContextCacheManagerTest do
  use ExUnit.Case, async: true

  alias ADK.Agents.ContextCacheConfig
  alias ADK.Models.CacheMetadata
  alias ADK.Models.GeminiContextCacheManager, as: Manager

  # -- Mock client for testing --

  defmodule MockClient do
    @moduledoc false

    def create_cache(_model, _config) do
      {:ok, %{name: "projects/test/locations/us-central1/cachedContents/new456"}}
    end

    def delete_cache(_name), do: :ok
  end

  defmodule FailingClient do
    @moduledoc false

    def create_cache(_model, _config), do: {:error, :api_error}
    def delete_cache(_name), do: {:error, :not_found}
  end

  # -- Helpers --

  defp cache_config(overrides \\ []) do
    defaults = [cache_intervals: 10, ttl_seconds: 1800, min_tokens: 0]
    struct(ContextCacheConfig, Keyword.merge(defaults, overrides))
  end

  defp make_contents(count) do
    for i <- 0..(count - 1) do
      %{role: "user", parts: [%{text: "Test message #{i}"}]}
    end
  end

  defp make_tools do
    [
      %{
        function_declarations: [
          %{
            name: "test_tool",
            description: "A test tool",
            parameters: %{type: "object", properties: %{param: %{type: "string"}}}
          }
        ]
      }
    ]
  end

  defp make_tool_config(mode \\ "AUTO") do
    %{function_calling_config: %{mode: mode}}
  end

  defp create_llm_request(opts \\ []) do
    contents_count = Keyword.get(opts, :contents_count, 3)
    cache_metadata = Keyword.get(opts, :cache_metadata, nil)

    %{
      model: "gemini-2.0-flash",
      contents: make_contents(contents_count),
      config: %{
        system_instruction: "Test instruction",
        tools: make_tools(),
        tool_config: make_tool_config()
      },
      cache_config: cache_config(),
      cache_metadata: cache_metadata
    }
  end

  defp create_cache_metadata(opts \\ []) do
    now = :os.system_time(:second)
    invocations_used = Keyword.get(opts, :invocations_used, 0)
    expired = Keyword.get(opts, :expired, false)
    contents_count = Keyword.get(opts, :contents_count, 3)

    expire_time =
      if expired do
        now - 300 + 0.0
      else
        now + 1800 + 0.0
      end

    CacheMetadata.new(
      cache_name: "projects/test/locations/us-central1/cachedContents/test123",
      expire_time: expire_time,
      fingerprint: "test_fingerprint",
      invocations_used: invocations_used,
      contents_count: contents_count,
      created_at: now - 600 + 0.0
    )
  end

  defp manager(client \\ MockClient) do
    Manager.new(client)
  end

  # -- Tests --

  describe "initialization" do
    test "creates manager with client" do
      m = Manager.new(MockClient)
      refute is_nil(m)
      assert m.client == MockClient
    end
  end

  describe "handle_context_caching/2" do
    test "no existing cache returns fingerprint-only metadata" do
      m = manager()
      req = create_llm_request(contents_count: 5)

      result = Manager.handle_context_caching(m, req)

      assert result != nil
      assert result.cache_name == nil
      assert result.expire_time == nil
      assert result.invocations_used == nil
      assert result.created_at == nil
      assert is_binary(result.fingerprint)
      assert result.contents_count == 5
    end

    test "valid existing cache is reused" do
      m = manager()
      existing = create_cache_metadata(invocations_used: 5)

      # Generate the correct fingerprint for the request with 3 contents
      req = create_llm_request(cache_metadata: existing)
      correct_fp = Manager.generate_cache_fingerprint(req, existing.contents_count)

      # Update existing metadata with correct fingerprint
      existing = %{existing | fingerprint: correct_fp}
      req = %{req | cache_metadata: existing}

      result = Manager.handle_context_caching(m, req)

      assert result != nil
      assert result.cache_name == existing.cache_name
      assert result.invocations_used == existing.invocations_used
      assert result.expire_time == existing.expire_time
      assert result.fingerprint == existing.fingerprint
      assert result.created_at == existing.created_at
    end

    test "invalid cache with fingerprint match creates new cache" do
      m = manager()
      # Exceeds cache_intervals of 10
      existing = create_cache_metadata(invocations_used: 15)
      req = create_llm_request(cache_metadata: existing)

      # Set the fingerprint to match current state
      correct_fp = Manager.generate_cache_fingerprint(req, existing.contents_count)
      existing = %{existing | fingerprint: correct_fp}

      req =
        req
        |> Map.put(:cache_metadata, existing)
        |> Map.put(:cacheable_contents_token_count, 2048)

      result = Manager.handle_context_caching(m, req)

      assert result != nil
      # New cache was created
      assert result.cache_name == "projects/test/locations/us-central1/cachedContents/new456"
    end

    test "invalid cache with fingerprint mismatch returns fingerprint-only" do
      m = manager()
      # Exceeds cache_intervals of 10, fingerprint won't match
      existing = create_cache_metadata(invocations_used: 15, contents_count: 3)
      req = create_llm_request(cache_metadata: existing, contents_count: 5)

      result = Manager.handle_context_caching(m, req)

      assert result != nil
      assert result.cache_name == nil
      assert result.expire_time == nil
      assert result.invocations_used == nil
      assert result.created_at == nil
      assert is_binary(result.fingerprint)
      assert result.contents_count == 5
    end
  end

  describe "is_cache_valid/1" do
    test "fingerprint mismatch returns false" do
      existing = create_cache_metadata()
      req = create_llm_request(cache_metadata: existing)
      # Fingerprint "test_fingerprint" won't match the generated one
      refute Manager.is_cache_valid(req)
    end

    test "expired cache returns false" do
      existing = create_cache_metadata(expired: true)
      req = create_llm_request(cache_metadata: existing)
      refute Manager.is_cache_valid(req)
    end

    test "fingerprint-only metadata returns false" do
      meta = CacheMetadata.fingerprint_only("test_fingerprint", 5)
      req = create_llm_request(cache_metadata: meta)
      refute Manager.is_cache_valid(req)
    end

    test "cache intervals exceeded returns false" do
      existing = create_cache_metadata(invocations_used: 15)
      req = create_llm_request(cache_metadata: existing)

      # Even with matching fingerprint, invocations exceeded
      correct_fp = Manager.generate_cache_fingerprint(req, existing.contents_count)
      existing = %{existing | fingerprint: correct_fp}
      req = %{req | cache_metadata: existing}

      refute Manager.is_cache_valid(req)
    end

    test "all checks pass returns true" do
      existing = create_cache_metadata(invocations_used: 5)
      req = create_llm_request(cache_metadata: existing)

      # Set correct fingerprint
      correct_fp = Manager.generate_cache_fingerprint(req, existing.contents_count)
      existing = %{existing | fingerprint: correct_fp}
      req = %{req | cache_metadata: existing}

      assert Manager.is_cache_valid(req)
    end
  end

  describe "cleanup_cache/2" do
    test "calls client delete" do
      # Use a test process to track calls
      m = manager()
      cache_name = "projects/test/locations/us-central1/cachedContents/test123"

      assert :ok = Manager.cleanup_cache(m, cache_name)
    end

    test "handles delete failure gracefully" do
      m = manager(FailingClient)
      cache_name = "projects/test/locations/us-central1/cachedContents/test123"

      # Should not raise
      assert :ok = Manager.cleanup_cache(m, cache_name)
    end
  end

  describe "generate_cache_fingerprint/2" do
    test "same request produces same fingerprint (deterministic)" do
      req = create_llm_request()

      fp1 = Manager.generate_cache_fingerprint(req, 2)
      fp2 = Manager.generate_cache_fingerprint(req, 2)

      assert fp1 == fp2
      assert is_binary(fp1)
      assert String.length(fp1) == 16
    end

    test "different requests produce different fingerprints" do
      req1 = create_llm_request()

      req2 = %{
        model: "gemini-2.0-flash",
        contents: [%{role: "user", parts: [%{text: "Different message"}]}],
        config: %{system_instruction: "Different instruction"},
        cache_config: cache_config()
      }

      fp1 = Manager.generate_cache_fingerprint(req1, 2)
      fp2 = Manager.generate_cache_fingerprint(req2, 1)

      assert fp1 != fp2
    end

    test "different tool_config produces different fingerprints" do
      req_auto = create_llm_request()

      req_none = %{
        model: "gemini-2.0-flash",
        contents: [%{role: "user", parts: [%{text: "Test"}]}],
        config: %{
          system_instruction: "Test instruction",
          tools: make_tools(),
          tool_config: make_tool_config("NONE")
        },
        cache_config: cache_config()
      }

      fp_auto = Manager.generate_cache_fingerprint(req_auto, 1)
      fp_none = Manager.generate_cache_fingerprint(req_none, 1)

      assert fp_auto != fp_none
    end

    test "request without tools has different fingerprint" do
      req_with_tools = create_llm_request()

      req_no_tools = %{
        model: "gemini-2.0-flash",
        contents: [%{role: "user", parts: [%{text: "Test"}]}],
        config: %{system_instruction: "Test instruction"},
        cache_config: cache_config()
      }

      fp1 = Manager.generate_cache_fingerprint(req_with_tools, 1)
      fp2 = Manager.generate_cache_fingerprint(req_no_tools, 1)

      assert fp1 != fp2
    end
  end

  describe "populate_cache_metadata_in_response/2" do
    test "preserves invocations_used" do
      response = %{
        content: %{role: "model", parts: [%{text: "hello"}]},
        usage_metadata: %{cached_content_token_count: 800, prompt_token_count: 1000}
      }

      cache_meta = create_cache_metadata(invocations_used: 3)

      updated = Manager.populate_cache_metadata_in_response(response, cache_meta)

      assert updated.cache_metadata.invocations_used == 3
      assert updated.cache_metadata.cache_name == cache_meta.cache_name
      assert updated.cache_metadata.fingerprint == cache_meta.fingerprint
      assert updated.cache_metadata.expire_time == cache_meta.expire_time
      assert updated.cache_metadata.created_at == cache_meta.created_at
    end

    test "works without usage_metadata" do
      response = %{
        content: %{role: "model", parts: [%{text: "hello"}]},
        usage_metadata: nil
      }

      cache_meta = create_cache_metadata(invocations_used: 3)

      updated = Manager.populate_cache_metadata_in_response(response, cache_meta)

      assert updated.cache_metadata.invocations_used == 3
      assert updated.cache_metadata.cache_name == cache_meta.cache_name
    end
  end

  describe "apply_cache_to_request/3" do
    test "removes system_instruction, tools, tool_config and sets cached_content" do
      req = create_llm_request(contents_count: 5)
      cache_name = "projects/test/cachedContents/abc"

      updated = Manager.apply_cache_to_request(req, cache_name, 3)

      # Config should have cached_content but no system_instruction/tools/tool_config
      refute Map.has_key?(updated.config, :system_instruction)
      refute Map.has_key?(updated.config, :tools)
      refute Map.has_key?(updated.config, :tool_config)
      assert updated.config.cached_content == cache_name

      # Contents should be trimmed
      assert length(updated.contents) == 2
    end
  end

  describe "create_gemini_cache/3" do
    test "creates cache with proper TTL" do
      m = manager()
      req = create_llm_request()
      cache_contents_count = max(0, length(req.contents) - 1)

      {:ok, metadata} = Manager.create_gemini_cache(m, req, cache_contents_count)

      assert metadata.cache_name == "projects/test/locations/us-central1/cachedContents/new456"
      assert metadata.invocations_used == 1
      assert metadata.contents_count == cache_contents_count
      assert is_binary(metadata.fingerprint)
      assert is_float(metadata.expire_time)
      assert is_float(metadata.created_at)
    end

    test "handles client failure" do
      m = manager(FailingClient)
      req = create_llm_request()

      assert {:error, :api_error} = Manager.create_gemini_cache(m, req, 2)
    end
  end

  describe "content counting" do
    test "cache all but last content" do
      req_multi = create_llm_request(contents_count: 5)
      cache_count = max(0, length(req_multi.contents) - 1)
      assert cache_count == 4

      req_single = create_llm_request(contents_count: 1)
      single_count = max(0, length(req_single.contents) - 1)
      assert single_count == 0
    end
  end

  describe "edge cases" do
    test "nil cache_config handled gracefully for fingerprint" do
      req = %{
        model: "gemini-2.0-flash",
        contents: [%{role: "user", parts: [%{text: "Test"}]}],
        config: %{system_instruction: "Test"},
        cache_config: nil
      }

      fp = Manager.generate_cache_fingerprint(req, 1)
      assert is_binary(fp)
      assert String.length(fp) == 16
    end

    test "empty contents handled gracefully" do
      req = %{
        model: "gemini-2.0-flash",
        contents: [],
        config: %{system_instruction: "Test"},
        cache_config: cache_config()
      }

      fp = Manager.generate_cache_fingerprint(req, 0)
      assert is_binary(fp)
      assert String.length(fp) == 16
    end

    test "no existing cache with sufficient token count returns fingerprint-only" do
      m = manager()
      req = create_llm_request(contents_count: 3)
      req = Map.put(req, :cacheable_contents_token_count, 2048)

      result = Manager.handle_context_caching(m, req)

      assert result != nil
      assert result.cache_name == nil
      assert is_binary(result.fingerprint)
      assert result.contents_count == 3
    end

    test "no existing cache with insufficient token count returns fingerprint-only" do
      m = manager()

      cc = cache_config(min_tokens: 2048)

      req =
        create_llm_request(contents_count: 3)
        |> Map.put(:cache_config, cc)
        |> Map.put(:cacheable_contents_token_count, 1024)

      result = Manager.handle_context_caching(m, req)

      assert result != nil
      assert result.cache_name == nil
      assert is_binary(result.fingerprint)
    end

    test "no existing cache without token count returns fingerprint-only" do
      m = manager()
      req = create_llm_request(contents_count: 3)
      req = Map.put(req, :cacheable_contents_token_count, nil)

      result = Manager.handle_context_caching(m, req)

      assert result != nil
      assert result.cache_name == nil
      assert is_binary(result.fingerprint)
    end
  end

  describe "parameter types" do
    test "populate_cache_metadata_in_response with correct types" do
      response = %{
        content: %{},
        usage_metadata: %{cached_content_token_count: 500, prompt_token_count: 1000}
      }

      cache_meta = create_cache_metadata(invocations_used: 3)
      updated = Manager.populate_cache_metadata_in_response(response, cache_meta)

      # No increment in this method
      assert updated.cache_metadata.invocations_used == 3
      assert %CacheMetadata{} = cache_meta
      assert Map.has_key?(response, :usage_metadata)
      refute Map.has_key?(cache_meta, :usage_metadata)
    end
  end
end
