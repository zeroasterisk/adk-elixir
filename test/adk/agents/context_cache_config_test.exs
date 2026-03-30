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

defmodule ADK.Agents.ContextCacheConfigTest do
  use ExUnit.Case, async: true

  alias ADK.Agents.ContextCacheConfig

  describe "new/1" do
    test "default values" do
      config = ContextCacheConfig.new()

      assert config.cache_intervals == 10
      assert config.ttl_seconds == 1800
      assert config.min_tokens == 0
    end

    test "custom values" do
      config =
        ContextCacheConfig.new(
          cache_intervals: 15,
          ttl_seconds: 3600,
          min_tokens: 1024
        )

      assert config.cache_intervals == 15
      assert config.ttl_seconds == 3600
      assert config.min_tokens == 1024
    end
  end

  describe "validation" do
    test "cache_intervals validation" do
      # Valid range
      assert %ContextCacheConfig{cache_intervals: 1} = ContextCacheConfig.new(cache_intervals: 1)

      assert %ContextCacheConfig{cache_intervals: 100} =
               ContextCacheConfig.new(cache_intervals: 100)

      # Invalid: too low
      assert_raise RuntimeError, ~r/greater than or equal to 1/, fn ->
        ContextCacheConfig.new(cache_intervals: 0)
      end

      # Invalid: too high
      assert_raise RuntimeError, ~r/less than or equal to 100/, fn ->
        ContextCacheConfig.new(cache_intervals: 101)
      end
    end

    test "ttl_seconds validation" do
      # Valid range
      assert %ContextCacheConfig{ttl_seconds: 1} = ContextCacheConfig.new(ttl_seconds: 1)
      assert %ContextCacheConfig{ttl_seconds: 86400} = ContextCacheConfig.new(ttl_seconds: 86400)

      # Invalid: zero or negative
      assert_raise RuntimeError, ~r/greater than 0/, fn ->
        ContextCacheConfig.new(ttl_seconds: 0)
      end

      assert_raise RuntimeError, ~r/greater than 0/, fn ->
        ContextCacheConfig.new(ttl_seconds: -1)
      end
    end

    test "min_tokens validation" do
      # Valid values
      assert %ContextCacheConfig{min_tokens: 0} = ContextCacheConfig.new(min_tokens: 0)
      assert %ContextCacheConfig{min_tokens: 1024} = ContextCacheConfig.new(min_tokens: 1024)

      # Invalid: negative
      assert_raise RuntimeError, ~r/greater than or equal to 0/, fn ->
        ContextCacheConfig.new(min_tokens: -1)
      end
    end
  end

  describe "ttl_string/1" do
    test "returns correct format" do
      config = ContextCacheConfig.new(ttl_seconds: 1800)
      assert ContextCacheConfig.ttl_string(config) == "1800s"

      config = ContextCacheConfig.new(ttl_seconds: 3600)
      assert ContextCacheConfig.ttl_string(config) == "3600s"
    end
  end

  describe "to_string/1" do
    test "string representation for logging" do
      config =
        ContextCacheConfig.new(
          cache_intervals: 15,
          ttl_seconds: 3600,
          min_tokens: 1024
        )

      expected =
        "ContextCacheConfig(cache_intervals=15, ttl=3600s, min_tokens=1024)"

      assert to_string(config) == expected
    end

    test "string representation with default values" do
      config = ContextCacheConfig.new()

      expected = "ContextCacheConfig(cache_intervals=10, ttl=1800s, min_tokens=0)"
      assert to_string(config) == expected
    end
  end

  describe "realistic scenarios" do
    test "realistic configuration scenarios" do
      # Quick caching for development
      dev_config =
        ContextCacheConfig.new(
          cache_intervals: 5,
          ttl_seconds: 600,
          min_tokens: 0
        )

      assert dev_config.cache_intervals == 5
      assert dev_config.ttl_seconds == 600

      # Production caching
      prod_config =
        ContextCacheConfig.new(
          cache_intervals: 20,
          ttl_seconds: 7200,
          min_tokens: 2048
        )

      assert prod_config.cache_intervals == 20
      assert prod_config.ttl_seconds == 7200
      assert prod_config.min_tokens == 2048

      # Conservative caching
      conservative_config =
        ContextCacheConfig.new(
          cache_intervals: 3,
          ttl_seconds: 300,
          min_tokens: 4096
        )

      assert conservative_config.cache_intervals == 3
      assert conservative_config.ttl_seconds == 300
      assert conservative_config.min_tokens == 4096
    end
  end
end
