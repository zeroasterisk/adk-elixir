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

defmodule Adk.WebServer.CorsRegexTest do
  use ExUnit.Case, async: true

  alias Adk.WebServer.Cors

  describe "_parse_cors_origins" do
    test "parses literal origins only" do
      origins = ["https://example.com", "https://test.com"]
      assert Cors.parse_origins(origins) == {:ok, ["https://example.com", "https://test.com"], nil}
    end

    test "parses regex patterns only" do
      origins = ["regex:https://.*\\.example\\.com", "regex:https://.*\\.test\\.com"]
      expected_regex = "https://.*\\.example\\.com|https://.*\\.test\\.com"
      assert Cors.parse_origins(origins) == {:ok, [], expected_regex}
    end

    test "parses mixed literal and regex" do
      origins = [
        "https://example.com",
        "regex:https://.*\\.subdomain\\.com",
        "https://test.com",
        "regex:https://tenant-.*\\.myapp\\.com"
      ]
      expected_regex = "https://.*\\.subdomain\\.com|https://tenant-.*\\.myapp\\.com"
      assert Cors.parse_origins(origins) == {:ok, ["https://example.com", "https://test.com"], expected_regex}
    end

    test "parses wildcard origin" do
      origins = ["*"]
      assert Cors.parse_origins(origins) == {:ok, ["*"], nil}
    end

    test "parses single regex" do
      origins = ["regex:https://.*\\.example\\.com"]
      assert Cors.parse_origins(origins) == {:ok, [], "https://.*\\.example\\.com"}
    end

    test "handles nil origins" do
      assert Cors.parse_origins(nil) == {:ok, [], nil}
    end

    test "handles empty list of origins" do
      assert Cors.parse_origins([]) == {:ok, [], nil}
    end
  end
end
