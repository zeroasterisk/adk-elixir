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
    def refresh(cred, _scheme \\ nil), do: {:ok, Map.put(cred, :refreshed, true)}
    @impl true
    def refresh_needed?(_cred, _scheme \\ nil), do: {:ok, false}
  end

  defmodule ExpiredRefresher do
    @behaviour ADK.Auth.Refresher
    @impl true
    def refresh(cred, _scheme \\ nil), do: {:ok, Map.put(cred, :refreshed, true)}
    @impl true
    def refresh_needed?(_cred, _scheme \\ nil), do: {:ok, true}
  end

  defmodule NeverRefresher do
    @behaviour ADK.Auth.Refresher
    @impl true
    def refresh(cred, _scheme \\ nil), do: {:ok, cred}
    @impl true
    def refresh_needed?(_cred, _scheme \\ nil), do: {:ok, false}
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
    test "refresh/2 returns updated credential" do
      cred = %{type: :oauth2, token: "old"}
      assert {:ok, updated} = AlwaysRefresher.refresh(cred, nil)
      assert updated.refreshed == true
    end

    test "refresh_needed?/2 returns {:ok, false} for AlwaysRefresher" do
      assert {:ok, false} = AlwaysRefresher.refresh_needed?(%{token: "abc"}, nil)
    end

    test "refresh_needed?/2 returns {:ok, true} for ExpiredRefresher" do
      assert {:ok, true} = ExpiredRefresher.refresh_needed?(%{token: "old"}, nil)
    end

    test "NeverRefresher.refresh/2 returns credential unchanged" do
      cred = %{type: :api_key, key: "secret"}
      assert {:ok, ^cred} = NeverRefresher.refresh(cred, nil)
    end
  end

  describe "full refresh lifecycle (via registry lookup)" do
    test "look up refresher, check expiry, refresh credential" do
      Registry.register(:oauth2, ExpiredRefresher)
      refresher = Registry.get_refresher(:oauth2)
      cred = %{type: :oauth2, token: "stale"}

      assert {:ok, true} = refresher.refresh_needed?(cred, nil)
      assert {:ok, refreshed} = refresher.refresh(cred, nil)
      assert refreshed.refreshed == true
    end

    test "skip refresh when not expired" do
      Registry.register(:api_key, NeverRefresher)
      refresher = Registry.get_refresher(:api_key)
      cred = %{type: :api_key, key: "valid"}
      assert {:ok, false} = refresher.refresh_needed?(cred, nil)
      # no refresh needed, credential unchanged
      assert {:ok, ^cred} = refresher.refresh(cred, nil)
    end
  end
end
