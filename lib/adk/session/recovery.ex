defmodule ADK.Session.Recovery do
  @moduledoc """
  Recovers active sessions after application restart.

  On application boot, scans the configured session store for sessions that
  were active (not completed/failed) and restarts their GenServer processes
  under the SessionSupervisor.

  ## Usage

      # In your Application.start/2, after starting the supervisor:
      ADK.Session.Recovery.recover(store: {ADK.Session.Store.JsonFile, [base_path: "sessions/"]})

      # Or with options:
      ADK.Session.Recovery.recover(
        store: {ADK.Session.Store.JsonFile, [base_path: "sessions/"]},
        auto_save: true,
        filter: fn session -> session.app_name == "my_app" end
      )

  Beyond Python ADK: This module has no equivalent in the Python ADK.
  """

  require Logger

  @doc """
  Scan the session store and restart active sessions.

  Options:
    - `:store` — `{module, opts}` tuple for the session store (required)
    - `:auto_save` — whether recovered sessions auto-save on terminate (default: true)
    - `:filter` — optional function to filter which sessions to recover
    - `:timeout` — max time to wait for all recoveries (default: 30_000ms)

  Returns `{:ok, recovered_count}` or `{:error, reason}`.
  """
  @spec recover(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def recover(opts) do
    store = Keyword.fetch!(opts, :store)
    auto_save = Keyword.get(opts, :auto_save, true)
    filter_fn = Keyword.get(opts, :filter, fn _ -> true end)

    case list_sessions(store) do
      {:ok, sessions} ->
        to_recover = Enum.filter(sessions, filter_fn)

        results =
          Enum.map(to_recover, fn session_meta ->
            recover_session(session_meta, store, auto_save)
          end)

        {ok, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

        if failed != [] do
          Logger.warning("[Session.Recovery] #{length(failed)} session(s) failed to recover")
        end

        Logger.info("[Session.Recovery] Recovered #{length(ok)}/#{length(to_recover)} session(s)")

        {:ok, length(ok)}

      {:error, reason} ->
        Logger.error("[Session.Recovery] Failed to list sessions: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Private ---

  defp list_sessions({mod, opts}) do
    cond do
      function_exported?(mod, :list_all, 1) ->
        mod.list_all(opts)

      function_exported?(mod, :list_recoverable, 0) ->
        mod.list_recoverable()

      true ->
        # Store doesn't support listing all sessions — can't auto-recover
        {:error, :list_all_not_supported}
    end
  end

  defp recover_session(session_meta, store, auto_save) do
    opts = [
      app_name: session_meta[:app_name] || session_meta["app_name"],
      user_id: session_meta[:user_id] || session_meta["user_id"],
      session_id: session_meta[:id] || session_meta["id"],
      store: store,
      auto_save: auto_save
    ]

    case ADK.Session.start_supervised(opts) do
      {:ok, pid} ->
        Logger.debug(
          "[Session.Recovery] Recovered session #{opts[:session_id]} (pid: #{inspect(pid)})"
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Already running — that's fine
        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          "[Session.Recovery] Failed to recover session #{opts[:session_id]}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
