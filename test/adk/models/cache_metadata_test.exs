defmodule ADK.Models.CacheMetadataTest do
  use ExUnit.Case, async: true

  alias ADK.Models.CacheMetadata

  describe "new/1" do
    test "test_required_fields" do
      # Test that all required fields must be provided
      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 5,
          contents_count: 3
        )

      assert meta.cache_name == "projects/123/locations/us-central1/cachedContents/456"
      assert meta.expire_time > :os.system_time(:second)
      assert meta.fingerprint == "abc123"
      assert meta.invocations_used == 5
      assert meta.contents_count == 3
      assert meta.created_at == nil
    end

    test "test_optional_created_at" do
      # Test that created_at is optional
      current_time = :os.system_time(:second) + 0.0

      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: current_time + 1800.0,
          fingerprint: "abc123",
          invocations_used: 3,
          contents_count: 2,
          created_at: current_time
        )

      assert meta.created_at == current_time
    end

    test "test_invocations_used_validation" do
      # Valid: zero or positive
      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 0,
          contents_count: 1
        )

      assert meta.invocations_used == 0

      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 10,
          contents_count: 1
        )

      assert meta.invocations_used == 10

      # Invalid: negative
      assert_raise ArgumentError, ~r/invocations_used must be greater than or equal to 0/, fn ->
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: -1,
          contents_count: 1
        )
      end
    end

    test "test_contents_count_validation" do
      # Valid: zero or positive
      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 1,
          contents_count: 0
        )

      assert meta.contents_count == 0

      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 1,
          contents_count: 10
        )

      assert meta.contents_count == 10

      # Invalid: negative
      assert_raise ArgumentError, ~r/contents_count must be greater than or equal to 0/, fn ->
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 1,
          contents_count: -1
        )
      end
    end

    test "test_immutability" do
      # In Elixir structs are inherently immutable. We can just assert that 
      # trying to mutate via map update doesn't change the original.
      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 5,
          contents_count: 3
        )

      _new_meta = %{meta | invocations_used: 10}
      assert meta.invocations_used == 5
    end

    test "test_missing_required_fields" do
      # Only fingerprint and contents_count are required
      assert_raise ArgumentError, fn ->
        CacheMetadata.new(contents_count: 2)
      end

      assert_raise ArgumentError, fn ->
        CacheMetadata.new(fingerprint: "abc123")
      end

      meta = CacheMetadata.new(fingerprint: "abc123", contents_count: 5)
      assert meta.cache_name == nil
      assert meta.expire_time == nil
      assert meta.invocations_used == nil
      assert meta.created_at == nil
    end
  end

  describe "expire_soon?/1" do
    test "test_expire_soon_property" do
      # Cache that expires in 10 minutes (should not expire soon)
      future_time = :os.system_time(:second) + 600.0

      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: future_time,
          fingerprint: "abc123",
          invocations_used: 1,
          contents_count: 1
        )

      refute CacheMetadata.expire_soon?(meta)

      # Cache that expires in 1 minute (should expire soon)
      soon_time = :os.system_time(:second) + 60.0

      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: soon_time,
          fingerprint: "abc123",
          invocations_used: 1,
          contents_count: 1
        )

      assert CacheMetadata.expire_soon?(meta)
    end
  end

  describe "String.Chars" do
    test "test_str_representation" do
      current_time = :os.system_time(:second) + 0.0
      expire_time = current_time + 1800.0

      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/test456",
          expire_time: expire_time,
          fingerprint: "abc123",
          invocations_used: 7,
          contents_count: 4
        )

      str_repr = to_string(meta)
      assert str_repr =~ "test456"
      assert str_repr =~ "used 7 invocations"
      assert str_repr =~ "cached 4 contents"
      assert str_repr =~ "expires in"
    end

    test "test_cache_name_extraction" do
      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/extracted_id",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 1,
          contents_count: 2
        )

      str_repr = to_string(meta)
      assert str_repr =~ "extracted_id"
    end
  end

  describe "fingerprint_only/2" do
    test "creates fingerprint-only metadata" do
      meta = CacheMetadata.fingerprint_only("abc123def456", 5)

      assert meta.cache_name == nil
      assert meta.expire_time == nil
      assert meta.fingerprint == "abc123def456"
      assert meta.invocations_used == nil
      assert meta.contents_count == 5
      assert meta.created_at == nil
    end

    test "validates contents_count in fingerprint_only" do
      assert_raise ArgumentError, ~r/contents_count must be greater than or equal to 0/, fn ->
        CacheMetadata.fingerprint_only("abc", -1)
      end
    end
  end

  describe "realistic cache scenarios" do
    test "test_realistic_cache_scenarios" do
      current_time = :os.system_time(:second) + 0.0

      # Fresh cache
      fresh_cache =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/fresh123",
          expire_time: current_time + 1800.0,
          fingerprint: "fresh_fingerprint",
          invocations_used: 1,
          contents_count: 5,
          created_at: current_time
        )

      assert fresh_cache.invocations_used == 1
      refute CacheMetadata.expire_soon?(fresh_cache)

      # Well-used cache
      used_cache =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/used456",
          expire_time: current_time + 600.0,
          fingerprint: "used_fingerprint",
          invocations_used: 8,
          contents_count: 3,
          created_at: current_time - 1200.0
        )

      assert used_cache.invocations_used == 8

      # Expiring cache
      expiring_cache =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/expiring789",
          expire_time: current_time + 60.0,
          fingerprint: "expiring_fingerprint",
          invocations_used: 15,
          contents_count: 10
        )

      assert CacheMetadata.expire_soon?(expiring_cache)
    end

    test "test_no_performance_metrics" do
      meta =
        CacheMetadata.new(
          cache_name: "projects/123/locations/us-central1/cachedContents/456",
          expire_time: :os.system_time(:second) + 1800.0,
          fingerprint: "abc123",
          invocations_used: 5,
          contents_count: 3
        )

      # Verify that token counts are NOT in CacheMetadata struct fields
      refute Map.has_key?(meta, :cached_tokens)
      refute Map.has_key?(meta, :total_tokens)
      refute Map.has_key?(meta, :prompt_tokens)
    end
  end
end
