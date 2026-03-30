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

defmodule ADK.Auth.ToolsetAuthTest do
  @moduledoc """
  Tests for toolset-level authentication.

  Parity with Python ADK's `tests/unittests/auth/test_toolset_auth.py`.
  Covers:
  - Prefix constants consistency
  - resolve_toolset_auth: no tools, no auth config, credential available,
    credential missing (yields auth event), multiple toolsets
  - build_auth_request_event: single/multiple requests, custom author/role,
    long_running_tool_ids
  - Toolset auth prefix skipping in preprocessor
  """
  use ExUnit.Case, async: true

  alias ADK.Auth.{Config, Credential, Preprocessor, ToolsetAuth}

  # ---------------------------------------------------------------------------
  # Mock toolset module — no auth
  # ---------------------------------------------------------------------------

  defmodule NoAuthToolset do
    @behaviour ADK.Tool.Toolset

    @impl true
    def get_auth_config, do: nil

    @impl true
    def get_tools(_ctx), do: []

    @impl true
    def close, do: :ok
  end

  # ---------------------------------------------------------------------------
  # Mock toolset module — has OAuth2 auth config
  # ---------------------------------------------------------------------------

  defmodule OAuthToolset do
    @behaviour ADK.Tool.Toolset

    @impl true
    def get_auth_config do
      Config.new(
        credential_type: :oauth2,
        required: true,
        scopes: ["read"],
        raw_credential:
          Credential.oauth2(nil,
            client_id: "test_client_id",
            client_secret: "test_client_secret"
          )
      )
    end

    @impl true
    def get_tools(_ctx), do: []

    @impl true
    def close, do: :ok
  end

  # ---------------------------------------------------------------------------
  # Mock toolset module — second OAuth toolset (different name)
  # ---------------------------------------------------------------------------

  defmodule OAuthToolset2 do
    @behaviour ADK.Tool.Toolset

    @impl true
    def get_auth_config do
      Config.new(
        credential_type: :oauth2,
        required: true,
        scopes: ["write"],
        raw_credential:
          Credential.oauth2(nil,
            client_id: "test_client_id_2",
            client_secret: "test_client_secret_2"
          )
      )
    end

    @impl true
    def get_tools(_ctx), do: []

    @impl true
    def close, do: :ok
  end

  # ---------------------------------------------------------------------------
  # Fake credential manager that always returns a credential
  # ---------------------------------------------------------------------------

  defmodule FakeCredentialManager do
    @doc false
    def get_credential(_name, _raw, _opts) do
      {:ok, Credential.oauth2("test-access-token")}
    end
  end

  # ---------------------------------------------------------------------------
  # Fake credential manager that returns :needs_auth (no credential)
  # ---------------------------------------------------------------------------

  defmodule NeedsAuthCredentialManager do
    @doc false
    def get_credential(_name, _raw, _opts) do
      :needs_auth
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_context(overrides \\ %{}) do
    base = %ADK.Context{
      invocation_id: "test-invocation-id",
      branch: nil,
      agent: %{name: "test-agent"},
      app_name: "test-app",
      user_id: "test-user"
    }

    Map.merge(base, overrides)
  end

  defp make_agent(tools) do
    %{name: "test-agent", tools: tools}
  end

  # =========================================================================
  # TestToolsetAuthPrefixConstant
  # =========================================================================

  describe "toolset auth prefix constant" do
    test "prefix constants match between preprocessor and toolset_auth" do
      assert Preprocessor.toolset_auth_prefix() == "_adk_toolset_auth_"
    end

    test "prefix is consistent string" do
      prefix = Preprocessor.toolset_auth_prefix()
      assert is_binary(prefix)
      assert String.starts_with?(prefix, "_adk_")
    end
  end

  # =========================================================================
  # TestResolveToolsetAuth
  # =========================================================================

  describe "resolve/3 — no tools" do
    test "returns no events when agent has no tools" do
      ctx = make_context()
      agent = make_agent([])

      {events, ended?} = ToolsetAuth.resolve(ctx, agent)

      assert events == []
      assert ended? == false
    end
  end

  describe "resolve/3 — toolset without auth config" do
    test "skips toolsets that return nil auth config" do
      ctx = make_context()
      agent = make_agent([NoAuthToolset])

      {events, ended?} = ToolsetAuth.resolve(ctx, agent)

      assert events == []
      assert ended? == false
    end
  end

  describe "resolve/3 — credential available" do
    test "populates config when credential is available" do
      ctx = make_context()
      agent = make_agent([OAuthToolset])

      {events, ended?} =
        ToolsetAuth.resolve(ctx, agent, credential_manager_mod: FakeCredentialManager)

      # No auth request events — credential was resolved
      assert events == []
      assert ended? == false
    end
  end

  describe "resolve/3 — credential not available" do
    test "yields auth request event when credential not available" do
      ctx = make_context()
      agent = make_agent([OAuthToolset])

      {events, ended?} =
        ToolsetAuth.resolve(ctx, agent, credential_manager_mod: NeedsAuthCredentialManager)

      assert length(events) == 1
      assert ended? == true

      [event] = events
      assert event.invocation_id == "test-invocation-id"
      assert event.author == "test-agent"
      assert event.content != nil

      parts = event.content["parts"]
      assert length(parts) == 1

      fc = hd(parts)["function_call"]
      assert fc["name"] == Preprocessor.request_euc_function_call_name()

      fc_id = fc["args"]["functionCallId"]
      assert String.starts_with?(fc_id, Preprocessor.toolset_auth_prefix())
      assert String.contains?(fc_id, "OAuthToolset")
    end
  end

  describe "resolve/3 — multiple toolsets needing auth" do
    test "yields single event with multiple function calls" do
      ctx = make_context()
      agent = make_agent([OAuthToolset, OAuthToolset2])

      {events, ended?} =
        ToolsetAuth.resolve(ctx, agent, credential_manager_mod: NeedsAuthCredentialManager)

      assert length(events) == 1
      assert ended? == true

      [event] = events
      parts = event.content["parts"]
      assert length(parts) == 2

      fc_ids =
        Enum.map(parts, fn p -> p["function_call"]["args"]["functionCallId"] end)
        |> MapSet.new()

      # Both should have toolset auth prefix
      Enum.each(fc_ids, fn id ->
        assert String.starts_with?(id, Preprocessor.toolset_auth_prefix())
      end)

      # Should have distinct IDs (different toolset names)
      assert MapSet.size(fc_ids) == 2
    end

    test "mix of authed and unauthed toolsets" do
      ctx = make_context()
      # NoAuthToolset has no auth config, OAuthToolset needs auth
      agent = make_agent([NoAuthToolset, OAuthToolset])

      {events, ended?} =
        ToolsetAuth.resolve(ctx, agent, credential_manager_mod: NeedsAuthCredentialManager)

      assert length(events) == 1
      assert ended? == true

      [event] = events
      parts = event.content["parts"]
      assert length(parts) == 1
    end
  end

  # =========================================================================
  # TestAuthPreprocessorToolsetAuthSkip
  # =========================================================================

  describe "preprocessor toolset auth skip" do
    test "toolset auth prefix is correctly identified" do
      prefix = Preprocessor.toolset_auth_prefix()
      toolset_fc_id = "#{prefix}McpToolset"
      assert String.starts_with?(toolset_fc_id, prefix)

      regular_fc_id = "call_123"
      refute String.starts_with?(regular_fc_id, prefix)
    end
  end

  # =========================================================================
  # TestBuildAuthRequestEvent
  # =========================================================================

  describe "build_auth_request_event/3" do
    test "builds event with single auth request" do
      ctx = make_context()

      auth_requests = %{
        "call_123" => Config.new(credential_type: :oauth2, scopes: ["read"])
      }

      event = ToolsetAuth.build_auth_request_event(ctx, auth_requests)

      assert event.invocation_id == "test-invocation-id"
      assert event.author == "test-agent"
      assert event.content != nil

      parts = event.content["parts"]
      assert length(parts) == 1

      fc = hd(parts)["function_call"]
      assert fc["name"] == Preprocessor.request_euc_function_call_name()
      assert fc["args"]["functionCallId"] == "call_123"
    end

    test "multiple auth requests create multiple parts" do
      ctx = make_context()

      auth_requests = %{
        "call_1" => Config.new(credential_type: :oauth2),
        "call_2" => Config.new(credential_type: :oauth2)
      }

      event = ToolsetAuth.build_auth_request_event(ctx, auth_requests)

      parts = event.content["parts"]
      assert length(parts) == 2

      fc_ids =
        Enum.map(parts, fn p -> p["function_call"]["args"]["functionCallId"] end)
        |> MapSet.new()

      assert fc_ids == MapSet.new(["call_1", "call_2"])
    end

    test "sets long_running_tool_ids in custom_metadata" do
      ctx = make_context()

      auth_requests = %{
        "call_123" => Config.new(credential_type: :oauth2)
      }

      event = ToolsetAuth.build_auth_request_event(ctx, auth_requests)

      lr_ids = event.custom_metadata[:long_running_tool_ids]
      assert is_list(lr_ids)
      assert length(lr_ids) == 1
      assert "call_123" in lr_ids
    end

    test "custom author overrides default agent name" do
      ctx = make_context()
      auth_requests = %{"call_1" => Config.new(credential_type: :oauth2)}

      event = ToolsetAuth.build_auth_request_event(ctx, auth_requests, author: "custom-author")

      assert event.author == "custom-author"
    end

    test "custom role is set in content" do
      ctx = make_context()
      auth_requests = %{"call_1" => Config.new(credential_type: :oauth2)}

      event = ToolsetAuth.build_auth_request_event(ctx, auth_requests, role: "user")

      assert event.content["role"] == "user"
    end

    test "default role is model" do
      ctx = make_context()
      auth_requests = %{"call_1" => Config.new(credential_type: :oauth2)}

      event = ToolsetAuth.build_auth_request_event(ctx, auth_requests)

      assert event.content["role"] == "model"
    end
  end

  # =========================================================================
  # Toolset behaviour detection
  # =========================================================================

  describe "ADK.Tool.Toolset.toolset?/1" do
    test "returns true for modules implementing Toolset behaviour" do
      assert ADK.Tool.Toolset.toolset?(NoAuthToolset)
      assert ADK.Tool.Toolset.toolset?(OAuthToolset)
    end

    test "returns false for non-toolset modules" do
      refute ADK.Tool.Toolset.toolset?(String)
      refute ADK.Tool.Toolset.toolset?(:not_a_module)
    end

    test "returns false for plain values" do
      refute ADK.Tool.Toolset.toolset?(42)
      refute ADK.Tool.Toolset.toolset?("hello")
      refute ADK.Tool.Toolset.toolset?(nil)
    end
  end
end
