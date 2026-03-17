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

defmodule ADK.Auth.Exchanger.RegistryTest do
  use ExUnit.Case, async: false

  alias ADK.Auth.Exchanger.Registry

  # Mock exchanger module for testing
  defmodule MockExchanger do
    @behaviour ADK.Auth.Exchanger

    @impl true
    def exchange(credential, _scheme) do
      {:ok, %{credential | type: :http_bearer}}
    end
  end

  # Another mock exchanger with custom return
  defmodule CustomExchanger do
    @behaviour ADK.Auth.Exchanger

    @impl true
    def exchange(_credential, _scheme) do
      {:ok, %ADK.Auth.Credential{type: :http_bearer, access_token: "exchanged-token"}}
    end
  end

  setup do
    Registry.clear()
    on_exit(fn -> Registry.clear() end)
    :ok
  end

  describe "initialization" do
    test "registry starts empty" do
      assert Registry.get_exchanger(:api_key) == nil
      assert Registry.get_exchanger(:oauth2) == nil
    end
  end

  describe "register/2" do
    test "registers a single exchanger" do
      :ok = Registry.register(:api_key, MockExchanger)
      assert Registry.get_exchanger(:api_key) == MockExchanger
    end

    test "registers multiple exchangers for different types" do
      :ok = Registry.register(:api_key, MockExchanger)
      :ok = Registry.register(:oauth2, CustomExchanger)
      :ok = Registry.register(:service_account, MockExchanger)

      assert Registry.get_exchanger(:api_key) == MockExchanger
      assert Registry.get_exchanger(:oauth2) == CustomExchanger
      assert Registry.get_exchanger(:service_account) == MockExchanger
    end

    test "overwrites existing exchanger for same type" do
      :ok = Registry.register(:api_key, MockExchanger)
      assert Registry.get_exchanger(:api_key) == MockExchanger

      :ok = Registry.register(:api_key, CustomExchanger)
      assert Registry.get_exchanger(:api_key) == CustomExchanger
    end

    test "registers nil exchanger" do
      :ok = Registry.register(:api_key, nil)
      assert Registry.get_exchanger(:api_key) == nil
    end

    test "registers exchangers for all credential types" do
      credential_types = [:api_key, :http_bearer, :oauth2, :open_id_connect, :service_account]

      modules =
        Enum.map(credential_types, fn type ->
          # Use MockExchanger for all — identity is by type key
          :ok = Registry.register(type, MockExchanger)
          {type, MockExchanger}
        end)

      for {type, mod} <- modules do
        assert Registry.get_exchanger(type) == mod
      end
    end
  end

  describe "get_exchanger/1" do
    test "returns correct module" do
      :ok = Registry.register(:http_bearer, MockExchanger)
      assert Registry.get_exchanger(:http_bearer) == MockExchanger
    end

    test "returns nil for nonexistent type" do
      assert Registry.get_exchanger(:oauth2) == nil
    end
  end

  describe "clear/0" do
    test "clears all registered exchangers" do
      :ok = Registry.register(:api_key, MockExchanger)
      :ok = Registry.register(:oauth2, CustomExchanger)

      assert Registry.get_exchanger(:api_key) == MockExchanger

      :ok = Registry.clear()

      assert Registry.get_exchanger(:api_key) == nil
      assert Registry.get_exchanger(:oauth2) == nil
    end
  end

  describe "isolation" do
    test "clear provides isolation between test scenarios" do
      # Scenario 1
      :ok = Registry.register(:api_key, MockExchanger)
      assert Registry.get_exchanger(:api_key) == MockExchanger

      Registry.clear()

      # Scenario 2 — previous registration gone
      assert Registry.get_exchanger(:api_key) == nil

      :ok = Registry.register(:api_key, CustomExchanger)
      assert Registry.get_exchanger(:api_key) == CustomExchanger
    end
  end

  describe "exchanger functionality through registry" do
    test "retrieved exchanger module can exchange credentials" do
      :ok = Registry.register(:api_key, CustomExchanger)

      exchanger = Registry.get_exchanger(:api_key)
      assert exchanger != nil

      input = %ADK.Auth.Credential{type: :api_key, api_key: "test-key"}
      {:ok, result} = exchanger.exchange(input, nil)

      assert result.type == :http_bearer
      assert result.access_token == "exchanged-token"
    end
  end

  describe "internal structure" do
    test "application env stores exchangers as a map" do
      :ok = Registry.register(:oauth2, MockExchanger)

      exchangers = Application.get_env(:adk, :auth_exchangers, %{})
      assert is_map(exchangers)
      assert Map.get(exchangers, :oauth2) == MockExchanger
      assert map_size(exchangers) == 1
    end
  end
end
