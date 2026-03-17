defmodule ADK.Auth.ProviderRegistryParityTest do
  @moduledoc """
  Parity tests for ADK.Auth.ProviderRegistry.

  Covers Python ADK's tests/unittests/auth/test_auth_provider_registry.py
  scenarios not already covered in provider_registry_test.exs:
  - Multi-type registration (register + retrieve two different types)
  - Duplicate type overwrite
  """

  use ExUnit.Case, async: false

  alias ADK.Auth.ProviderRegistry

  # Two distinct mock providers to simulate Python's SchemeA / SchemeB
  defmodule ProviderA do
    @behaviour ADK.Auth.Provider

    @impl true
    def get_auth_credential(_config, _context) do
      {:ok, ADK.Auth.Credential.api_key("provider_a")}
    end
  end

  defmodule ProviderB do
    @behaviour ADK.Auth.Provider

    @impl true
    def get_auth_credential(_config, _context) do
      {:ok, ADK.Auth.Credential.api_key("provider_b")}
    end
  end

  defmodule ProviderC do
    @behaviour ADK.Auth.Provider

    @impl true
    def get_auth_credential(_config, _context) do
      {:ok, ADK.Auth.Credential.api_key("provider_c")}
    end
  end

  setup do
    ProviderRegistry.clear()
    on_exit(fn -> ProviderRegistry.clear() end)
    :ok
  end

  describe "parity with test_auth_provider_registry.py" do
    test "register and get providers for different credential types" do
      # Python: test_register_and_get_provider — registers SchemeA→providerA, SchemeB→providerB
      ProviderRegistry.register(:oauth2, ProviderA)
      ProviderRegistry.register(:api_key, ProviderB)

      assert ProviderRegistry.get_provider(:oauth2) == ProviderA
      assert ProviderRegistry.get_provider(:api_key) == ProviderB
    end

    test "get unregistered provider returns nil" do
      # Python: test_get_unregistered_provider_returns_none
      assert ProviderRegistry.get_provider(:service_account) == nil
    end

    test "register duplicate type overwrites existing" do
      # Python: test_register_duplicate_type_overwrites_existing
      ProviderRegistry.register(:oauth2, ProviderA)
      ProviderRegistry.register(:oauth2, ProviderC)

      assert ProviderRegistry.get_provider(:oauth2) == ProviderC
    end
  end
end
