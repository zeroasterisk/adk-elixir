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

defmodule ADK.MCP.McpToolsetAuthTest do
  @moduledoc """
  Parity tests for MCP toolset auth behaviors, mirroring Python ADK's
  `tests/unittests/tools/mcp_tool/test_mcp_toolset_auth.py`.

  Tests:
  - `get_auth_config_returns_none_without_auth_scheme`
  - `get_auth_config_returns_config_with_auth_scheme`
  - `get_auth_headers_returns_none_without_auth_config`
  - `get_auth_headers_returns_none_without_exchanged_credential`
  - `get_auth_headers_oauth2_bearer_token`
  - `get_auth_headers_http_bearer_token`
  - `get_auth_headers_http_basic_auth`
  - `get_auth_headers_api_key_header`
  - `get_auth_headers_api_key_non_header_returns_nil` (or logs warning in Python)
  """
  use ExUnit.Case, async: true

  alias ADK.MCP.Toolset
  alias ADK.Auth.Config
  alias ADK.Auth.Credential

  defmodule MockMcpClient do
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [])
    end

    def close(pid) do
      GenServer.stop(pid)
    end

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end

    def server_info(_pid) do
      {:ok, %{}}
    end
  end

  describe "Toolset.get_auth_config/1" do
    test "returns nil when no auth configured" do
      {:ok, toolset} = Toolset.start_link(client_mod: MockMcpClient)

      assert Toolset.get_auth_config(toolset) == nil
    end

    test "returns Config when auth configured" do
      auth_config =
        Config.new(
          credential_type: :oauth2,
          raw_credential:
            Credential.oauth2(nil,
              client_id: "test_client_id",
              client_secret: "test_client_secret"
            )
        )

      {:ok, toolset} =
        Toolset.start_link(
          client_mod: MockMcpClient,
          auth_config: auth_config
        )

      config = Toolset.get_auth_config(toolset)
      assert config != nil
      assert config.credential_type == :oauth2
      assert config.raw_credential.client_id == "test_client_id"
    end
  end

  describe "Toolset.get_auth_headers/1" do
    setup do
      auth_config =
        Config.new(
          credential_type: :oauth2,
          raw_credential:
            Credential.oauth2(nil,
              client_id: "test_client_id",
              client_secret: "test_client_secret"
            )
        )

      {:ok, toolset} =
        Toolset.start_link(
          client_mod: MockMcpClient,
          auth_config: auth_config
        )

      %{toolset: toolset, auth_config: auth_config}
    end

    test "returns nil without auth config" do
      {:ok, toolset_no_auth} = Toolset.start_link(client_mod: MockMcpClient)

      assert Toolset.get_auth_headers(toolset_no_auth) == nil
    end

    test "returns nil without exchanged credential", %{toolset: toolset} do
      # No exchanged credential set yet
      assert Toolset.get_auth_headers(toolset) == nil
    end

    test "oauth2_bearer_token", %{toolset: toolset} do
      # Set exchanged credential with access token
      exchanged = Credential.oauth2("test-access-token")
      :ok = Toolset.set_exchanged_credential(toolset, exchanged)

      headers = Toolset.get_auth_headers(toolset)

      assert headers != nil
      assert headers["Authorization"] == "Bearer test-access-token"
    end

    test "http_bearer_token" do
      auth_config = Config.new(credential_type: :http_bearer)
      {:ok, toolset} = Toolset.start_link(client_mod: MockMcpClient, auth_config: auth_config)

      # Set exchanged credential with HTTP bearer token
      exchanged = Credential.http_bearer("test-bearer-token")
      :ok = Toolset.set_exchanged_credential(toolset, exchanged)

      headers = Toolset.get_auth_headers(toolset)

      assert headers != nil
      assert headers["Authorization"] == "Bearer test-bearer-token"
    end

    test "http_basic_auth" do
      auth_config = Config.new(credential_type: :http_basic)
      {:ok, toolset} = Toolset.start_link(client_mod: MockMcpClient, auth_config: auth_config)

      # Set exchanged credential with HTTP basic auth (using client_id for user and client_secret for pass)
      exchanged = %Credential{
        type: :http_basic,
        client_id: "testuser",
        client_secret: "testpass"
      }

      :ok = Toolset.set_exchanged_credential(toolset, exchanged)

      headers = Toolset.get_auth_headers(toolset)

      assert headers != nil
      expected_credentials = Base.encode64("testuser:testpass")
      assert headers["Authorization"] == "Basic #{expected_credentials}"
    end

    test "api_key_header" do
      auth_config = Config.new(credential_type: :api_key)
      {:ok, toolset} = Toolset.start_link(client_mod: MockMcpClient, auth_config: auth_config)

      # Set exchanged credential with API key, mapped to "X-API-Key" via metadata
      exchanged =
        Credential.api_key("test-api-key-12345",
          metadata: %{"header_name" => "X-API-Key", "in" => "header"}
        )

      :ok = Toolset.set_exchanged_credential(toolset, exchanged)

      headers = Toolset.get_auth_headers(toolset)

      assert headers != nil
      assert headers["X-API-Key"] == "test-api-key-12345"
    end

    test "api_key_non_header_returns_nil" do
      auth_config = Config.new(credential_type: :api_key)
      {:ok, toolset} = Toolset.start_link(client_mod: MockMcpClient, auth_config: auth_config)

      # Set exchanged credential with API key via query, not header
      exchanged = Credential.api_key("test-api-key-12345", metadata: %{"in" => "query"})
      :ok = Toolset.set_exchanged_credential(toolset, exchanged)

      headers = Toolset.get_auth_headers(toolset)

      # Should return nil for non-header API key
      assert headers == nil
    end
  end
end
