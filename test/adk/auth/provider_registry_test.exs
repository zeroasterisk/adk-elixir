defmodule ADK.Auth.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias ADK.Auth.ProviderRegistry

  defmodule DummyProvider do
    @behaviour ADK.Auth.Provider

    @impl true
    def get_auth_credential(_config, _context) do
      {:ok, ADK.Auth.Credential.api_key("dummy")}
    end
  end

  setup do
    ProviderRegistry.clear()
    on_exit(fn -> ProviderRegistry.clear() end)
    :ok
  end

  test "returns nil for unregistered provider" do
    assert ProviderRegistry.get_provider(:oauth2) == nil
  end

  test "registers and returns provider" do
    assert :ok = ProviderRegistry.register(:oauth2, DummyProvider)
    assert ProviderRegistry.get_provider(:oauth2) == DummyProvider
  end

  test "clears all providers" do
    ProviderRegistry.register(:oauth2, DummyProvider)
    assert ProviderRegistry.get_provider(:oauth2) == DummyProvider

    ProviderRegistry.clear()
    assert ProviderRegistry.get_provider(:oauth2) == nil
  end
end
