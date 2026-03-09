defmodule ADK.Memory.Store do
  @moduledoc """
  Behaviour for memory services.

  Provides long-term memory across sessions — agents can store and search
  memories scoped by app + user. Mirrors Python ADK's `BaseMemoryService`.

  ## Implementing a backend

      defmodule MyVectorStore do
        @behaviour ADK.Memory.Store

        @impl true
        def search(app_name, user_id, query, opts) do
          # your vector search here
          {:ok, []}
        end

        # ... other callbacks
      end
  """

  alias ADK.Memory.Entry

  @type scope :: {app_name :: String.t(), user_id :: String.t()}

  @doc "Search memories matching the query. Returns entries ranked by relevance."
  @callback search(
              app_name :: String.t(),
              user_id :: String.t(),
              query :: String.t(),
              opts :: keyword()
            ) :: {:ok, [Entry.t()]} | {:error, term()}

  @doc "Add memory entries."
  @callback add(
              app_name :: String.t(),
              user_id :: String.t(),
              entries :: [Entry.t()]
            ) :: :ok | {:error, term()}

  @doc "Add all events from a session to memory."
  @callback add_session(
              app_name :: String.t(),
              user_id :: String.t(),
              session_id :: String.t(),
              events :: [ADK.Event.t()]
            ) :: :ok | {:error, term()}

  @doc "Delete a specific memory entry by ID."
  @callback delete(
              app_name :: String.t(),
              user_id :: String.t(),
              entry_id :: String.t()
            ) :: :ok | {:error, term()}

  @doc "Delete all memories for a user scope."
  @callback clear(
              app_name :: String.t(),
              user_id :: String.t()
            ) :: :ok | {:error, term()}

  @optional_callbacks [clear: 2, add_session: 4]
end
