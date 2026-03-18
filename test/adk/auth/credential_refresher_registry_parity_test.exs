defmodule ADK.Auth.CredentialRefresherRegistryParityTest do
  @moduledoc """
  Parity tests for Python's `test_credential_refresher_registry.py`.

  Python tests `CredentialRefresherRegistry` which maps credential types to
  refresher callables/classes. Elixir equivalent: `ADK.Auth.Refresher.Registry`
  mapping atoms to modules implementing `ADK.Auth.Refresher`.
  """
  use ExUnit.Case, async: true

  alias ADK.Auth.Refresher
  alias ADK.Auth.Refresher.Registry

  # Minimal test refresher implementing the behaviour
  defmodule AlwaysRefresher do
    @behaviour ADK.Auth.Refresher
    @impl true
    def refresh(cred), do: {:ok, Map.put(cred, :refreshed, true)}
    @impl true
    def is_expired?(_cred), do: false
  end

  defmodule ExpiredRefresher do
    @behaviour ADK.Auth.Refresher
    @impl true
    def refresh(cred), do: {:ok, Map.put(cred, :refreshed, true)}
    @impl true
    def is_expired?(_cred), do: true
  end

  defmodule NeverRefresher do
    @behaviour ADK.Auth.Refresher
    @impl true
    def refresh(cred), do: {:ok, cred}
    @impl true
    def is_expired?(_cred), do: false
  end

  setup do
    # Isolate registry state per test
    prev = Application.get_env(:adk, :auth_refreshers, %{})
    on_exit(fn -> Application.put_env(:adk, :auth_refreshers, prev) end)
    Application.put_env(:adk, :auth_refreshers, %{})
    :ok
  end

  describe "registry operations (mirrors CredentialRefresherRegistry)" do
    test "get_refresher returns nil for unregistered type" do
      assert Registry.get_refresher(:oauth2) == nil
    end

    test "register and get_refresher round-trip" do
      Registry.register(:oauth2, AlwaysRefresher)
      assert Registry.get_refresher(:oauth2) == AlwaysRefresher
    end

    test "register multiple credential types" do
      Registry.register(:oauth2, AlwaysRefresher)
      Registry.register(:api_key, NeverRefresher)
      assert Registry.get_refresher(:oauth2) == AlwaysRefresher
      assert Registry.get_refresher(:api_key) == NeverRefresher
    end

    test "overwrite registration for same type" do
      Registry.register(:oauth2, AlwaysRefresher)
      Registry.register(:oauth2, NeverRefresher)
      assert Registry.get_refresher(:oauth2) == NeverRefresher
    end

    test "isolates registrations across independent setups" do
      # Registry starts empty (isolation via setup/on_exit)
      assert Registry.get_refresher(:oauth2) == nil
      Registry.register(:oauth2, AlwaysRefresher)
      assert Registry.get_refresher(:oauth2) == AlwaysRefresher
    end
  end

  describe "refresher behaviour (mirrors refresher contract)" do
    test "refresh/1 returns updated credential" do
      cred = %{type: :oauth2, token: "old"}
      assert {:ok, updated} = AlwaysRefresher.refresh(cred)
      assert updated.refreshed == true
    end

    test "is_expired?/1 returns false for AlwaysRefresher" do
      assert AlwaysRefresher.is_expired?(%{token: "abc"}) == false
    end

    test "is_expired?/1 returns true for ExpiredRefresher" do
      assert ExpiredRefresher.is_expired?(%{token: "old"}) == true
    end

    test "NeverRefresher.refresh/1 returns credential unchanged" do
      cred = %{type: :api_key, key: "secret"}
      assert {:ok, ^cred} = NeverRefresher.refresh(cred)
    end
  end

  describe "full refresh lifecycle (via registry lookup)" do
    test "look up refresher, check expiry, refresh credential" do
      Registry.register(:oauth2, ExpiredRefresher)
      refresher = Registry.get_refresher(:oauth2)
      cred = %{type: :oauth2, token: "stale"}

      if refresher.is_expired?(cred) do
        assert {:ok, refreshed} = refresher.refresh(cred)
        assert refreshed.refreshed == true
      end
    end

    test "skip refresh when not expired" do
      Registry.register(:api_key, NeverRefresher)
      refresher = Registry.get_refresher(:api_key)
      cred = %{type: :api_key, key: "valid"}
      refute refresher.is_expired?(cred)
      # no refresh needed, credential unchanged
      assert {:ok, ^cred} = refresher.refresh(cred)
    end
  end
end
