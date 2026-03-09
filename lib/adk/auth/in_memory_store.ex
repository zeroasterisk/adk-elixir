defmodule ADK.Auth.InMemoryStore do
  @moduledoc """
  In-memory credential store using an Agent process.

  Suitable for testing and development. Credentials are lost when the
  process stops.

  ## Usage

      {:ok, store} = ADK.Auth.InMemoryStore.start_link(name: :my_cred_store)
      :ok = ADK.Auth.InMemoryStore.put("api_service", credential, server: store)
      {:ok, cred} = ADK.Auth.InMemoryStore.get("api_service", server: store)
  """
  use Agent

  @behaviour ADK.Auth.CredentialStore

  @doc "Start the in-memory credential store."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @impl true
  def get(name, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case Agent.get(server, &Map.get(&1, name)) do
      nil -> :not_found
      cred -> {:ok, cred}
    end
  end

  @impl true
  def put(name, credential, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    Agent.update(server, &Map.put(&1, name, credential))
  end

  @impl true
  def delete(name, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    Agent.update(server, &Map.delete(&1, name))
  end
end
