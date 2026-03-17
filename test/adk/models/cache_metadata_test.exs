defmodule ADK.Models.CacheMetadataTest do
  use ExUnit.Case, async: true

  alias ADK.Models.CacheMetadata

  describe "new/1" do
    test "creates metadata from keyword list" do
      meta =
        CacheMetadata.new(
          cache_name: "projects/test/locations/us-central1/cachedContents/abc",
          expire_time: 1_700_000_000.0,
          fingerprint: "abcdef1234567890",
          invocations_used: 3,
          contents_count: 5,
          created_at: 1_699_999_000.0
        )

      assert meta.cache_name == "projects/test/locations/us-central1/cachedContents/abc"
      assert meta.expire_time == 1_700_000_000.0
      assert meta.fingerprint == "abcdef1234567890"
      assert meta.invocations_used == 3
      assert meta.contents_count == 5
      assert meta.created_at == 1_699_999_000.0
    end

    test "requires fingerprint and contents_count" do
      assert_raise ArgumentError, fn ->
        CacheMetadata.new(cache_name: "test")
      end

      assert_raise ArgumentError, fn ->
        CacheMetadata.new(fingerprint: "abc")
      end
    end

    test "defaults optional fields to nil" do
      meta = CacheMetadata.new(fingerprint: "abc", contents_count: 3)

      assert meta.cache_name == nil
      assert meta.expire_time == nil
      assert meta.invocations_used == nil
      assert meta.created_at == nil
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
  end

  describe "expire_soon?/1" do
    test "returns false when expire_time is nil" do
      meta = CacheMetadata.fingerprint_only("abc", 1)
      refute CacheMetadata.expire_soon?(meta)
    end

    test "returns false when cache has plenty of time" do
      future = :os.system_time(:second) + 3600

      meta =
        CacheMetadata.new(
          fingerprint: "abc",
          contents_count: 1,
          expire_time: future + 0.0,
          cache_name: "test"
        )

      refute CacheMetadata.expire_soon?(meta)
    end

    test "returns true when cache expires within 2 minutes" do
      soon = :os.system_time(:second) + 60

      meta =
        CacheMetadata.new(
          fingerprint: "abc",
          contents_count: 1,
          expire_time: soon + 0.0,
          cache_name: "test"
        )

      assert CacheMetadata.expire_soon?(meta)
    end

    test "returns true when cache already expired" do
      past = :os.system_time(:second) - 300

      meta =
        CacheMetadata.new(
          fingerprint: "abc",
          contents_count: 1,
          expire_time: past + 0.0,
          cache_name: "test"
        )

      assert CacheMetadata.expire_soon?(meta)
    end
  end

  describe "String.Chars" do
    test "fingerprint-only state" do
      meta = CacheMetadata.fingerprint_only("abcdef1234567890", 5)
      str = to_string(meta)

      assert str =~ "Fingerprint-only"
      assert str =~ "5 contents"
      assert str =~ "abcdef12..."
    end

    test "active cache state" do
      future = :os.system_time(:second) + 1800

      meta =
        CacheMetadata.new(
          cache_name: "projects/test/locations/us-central1/cachedContents/abc123",
          expire_time: future + 0.0,
          fingerprint: "fp",
          invocations_used: 3,
          contents_count: 10,
          created_at: :os.system_time(:second) - 600.0
        )

      str = to_string(meta)

      assert str =~ "Cache abc123"
      assert str =~ "used 3 invocations"
      assert str =~ "cached 10 contents"
      assert str =~ "expires in"
      assert str =~ "min"
    end

    test "active cache with nil expire_time" do
      meta =
        CacheMetadata.new(
          cache_name: "projects/test/locations/us/cachedContents/xyz",
          fingerprint: "fp",
          invocations_used: 1,
          contents_count: 5
        )

      str = to_string(meta)

      assert str =~ "Cache xyz"
      assert str =~ "expires unknown"
    end
  end
end
