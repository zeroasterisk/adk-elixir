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

defmodule ADK.Artifact.UtilTest do
  @moduledoc """
  Tests for ADK.Artifact.Util — parity with Python ADK's test_artifact_util.py.
  """
  use ExUnit.Case, async: true

  alias ADK.Artifact.Util

  # -------------------------------------------------------------------
  # parse_artifact_uri — session-scoped
  # -------------------------------------------------------------------

  describe "parse_artifact_uri/1 session-scoped" do
    test "parses a valid session-scoped artifact URI" do
      uri =
        "artifact://apps/app1/users/user1/sessions/session1/artifacts/file1/versions/123"

      parsed = Util.parse_artifact_uri(uri)
      assert parsed != nil
      assert parsed.app_name == "app1"
      assert parsed.user_id == "user1"
      assert parsed.session_id == "session1"
      assert parsed.filename == "file1"
      assert parsed.version == 123
    end
  end

  # -------------------------------------------------------------------
  # parse_artifact_uri — user-scoped
  # -------------------------------------------------------------------

  describe "parse_artifact_uri/1 user-scoped" do
    test "parses a valid user-scoped artifact URI" do
      uri = "artifact://apps/app2/users/user2/artifacts/file2/versions/456"
      parsed = Util.parse_artifact_uri(uri)
      assert parsed != nil
      assert parsed.app_name == "app2"
      assert parsed.user_id == "user2"
      assert parsed.session_id == nil
      assert parsed.filename == "file2"
      assert parsed.version == 456
    end
  end

  # -------------------------------------------------------------------
  # parse_artifact_uri — invalid URIs
  # -------------------------------------------------------------------

  describe "parse_artifact_uri/1 invalid URIs" do
    @invalid_uris [
      "http://example.com",
      "artifact://invalid",
      "artifact://app1/user1/sessions/session1/artifacts/file1",
      "artifact://apps/app1/users/user1/sessions/session1/artifacts/file1",
      "artifact://apps/app1/users/user1/artifacts/file1"
    ]

    for uri <- @invalid_uris do
      test "returns nil for #{uri}" do
        assert Util.parse_artifact_uri(unquote(uri)) == nil
      end
    end

    test "returns nil for nil input" do
      assert Util.parse_artifact_uri(nil) == nil
    end

    test "returns nil for empty string" do
      assert Util.parse_artifact_uri("") == nil
    end
  end

  # -------------------------------------------------------------------
  # get_artifact_uri — construction
  # -------------------------------------------------------------------

  describe "get_artifact_uri/5" do
    test "constructs a session-scoped artifact URI" do
      uri =
        Util.get_artifact_uri("app1", "user1", "file1", 123, session_id: "session1")

      assert uri ==
               "artifact://apps/app1/users/user1/sessions/session1/artifacts/file1/versions/123"
    end

    test "constructs a user-scoped artifact URI" do
      uri = Util.get_artifact_uri("app2", "user2", "file2", 456)

      assert uri ==
               "artifact://apps/app2/users/user2/artifacts/file2/versions/456"
    end
  end

  # -------------------------------------------------------------------
  # Round-trip: get → parse → verify
  # -------------------------------------------------------------------

  describe "round-trip" do
    test "session-scoped URI survives get → parse" do
      uri = Util.get_artifact_uri("a", "u", "f", 7, session_id: "s")
      parsed = Util.parse_artifact_uri(uri)
      assert parsed.app_name == "a"
      assert parsed.user_id == "u"
      assert parsed.session_id == "s"
      assert parsed.filename == "f"
      assert parsed.version == 7
    end

    test "user-scoped URI survives get → parse" do
      uri = Util.get_artifact_uri("a", "u", "f", 9)
      parsed = Util.parse_artifact_uri(uri)
      assert parsed.app_name == "a"
      assert parsed.user_id == "u"
      assert parsed.session_id == nil
      assert parsed.filename == "f"
      assert parsed.version == 9
    end
  end

  # -------------------------------------------------------------------
  # is_artifact_ref
  # -------------------------------------------------------------------

  describe "is_artifact_ref/1" do
    test "returns true for a part with artifact:// file_uri" do
      part = %{
        "file_data" => %{
          "file_uri" => "artifact://apps/a/users/u/sessions/s/artifacts/f/versions/1",
          "mime_type" => "text/plain"
        }
      }

      assert Util.is_artifact_ref(part) == true
    end

    test "returns false for a text part" do
      assert Util.is_artifact_ref(%{"text" => "hello"}) == false
    end

    test "returns false for an inline_data part" do
      part = %{"inline_data" => %{"data" => "MTIz", "mime_type" => "text/plain"}}
      assert Util.is_artifact_ref(part) == false
    end

    test "returns false for a non-artifact file_data part" do
      part = %{
        "file_data" => %{
          "file_uri" => "http://example.com",
          "mime_type" => "text/plain"
        }
      }

      assert Util.is_artifact_ref(part) == false
    end

    test "returns false for an empty map" do
      assert Util.is_artifact_ref(%{}) == false
    end

    test "returns false for nil" do
      assert Util.is_artifact_ref(nil) == false
    end
  end
end
