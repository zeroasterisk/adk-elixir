defmodule ADK.Session.Store.JsonFile do
  @moduledoc """
  File-based JSON session store.

  Stores each session as a JSON file at:
  `{base_path}/{app_name}/{user_id}/{session_id}.json`

  Good for development and simple deployments.

  ## Usage

      ADK.Session.start_link(
        app_name: "my_app",
        user_id: "user1",
        session_id: "sess1",
        store: {ADK.Session.Store.JsonFile, [base_path: "/tmp/sessions"]}
      )
  """

  @behaviour ADK.Session.Store

  @impl ADK.Session.Store
  def load(app_name, user_id, session_id) do
    path = session_path(app_name, user_id, session_id)

    case File.read(path) do
      {:ok, contents} ->
        {:ok, Jason.decode!(contents, keys: :atoms)}

      {:error, :enoent} ->
        {:error, :not_found}
    end
  end

  @impl ADK.Session.Store
  def save(session) do
    path = session_path(session.app_name, session.user_id, session.id)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    data = serialize_session(session)
    json = Jason.encode!(data, pretty: true)
    File.write!(path, json)
    :ok
  end

  @impl ADK.Session.Store
  def delete(app_name, user_id, session_id) do
    path = session_path(app_name, user_id, session_id)
    File.rm(path)
    :ok
  end

  @impl ADK.Session.Store
  def list(app_name, user_id) do
    dir = session_dir(app_name, user_id)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.replace_suffix(&1, ".json", ""))

      {:error, :enoent} ->
        []
    end
  end

  @doc """
  List all sessions across all apps and users.
  Returns `{:ok, [%{id: ..., app_name: ..., user_id: ...}]}`.

  Used by `ADK.Session.Recovery` to find sessions to restore after restart.
  """
  @spec list_all(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_all(_opts \\ []) do
    base = base_path()

    if File.dir?(base) do
      sessions =
        base
        |> File.ls!()
        |> Enum.flat_map(fn app_name ->
          app_dir = Path.join(base, app_name)

          if File.dir?(app_dir) do
            app_dir
            |> File.ls!()
            |> Enum.flat_map(fn user_id ->
              user_dir = Path.join(app_dir, user_id)

              if File.dir?(user_dir) do
                user_dir
                |> File.ls!()
                |> Enum.filter(&String.ends_with?(&1, ".json"))
                |> Enum.map(fn file ->
                  %{
                    id: String.replace_suffix(file, ".json", ""),
                    app_name: app_name,
                    user_id: user_id
                  }
                end)
              else
                []
              end
            end)
          else
            []
          end
        end)

      {:ok, sessions}
    else
      {:ok, []}
    end
  end

  # --- Helpers ---

  defp base_path do
    ADK.Config.json_store_path()
  end

  defp session_dir(app_name, user_id) do
    Path.join([base_path(), app_name, user_id])
  end

  defp session_path(app_name, user_id, session_id) do
    Path.join([session_dir(app_name, user_id), "#{session_id}.json"])
  end

  defp serialize_session(session) do
    %{
      id: session.id,
      app_name: session.app_name,
      user_id: session.user_id,
      state: session.state,
      events: Enum.map(session.events, &serialize_event/1)
    }
  end

  defp serialize_event(%ADK.Event{} = event) do
    %{
      id: event.id,
      invocation_id: event.invocation_id,
      author: event.author,
      branch: event.branch,
      timestamp: event.timestamp && DateTime.to_iso8601(event.timestamp),
      content: event.content,
      partial: event.partial,
      actions: serialize_actions(event.actions),
      error: sanitize_for_json(event.error)
    }
  end

  defp serialize_event(event), do: event

  defp serialize_actions(%ADK.EventActions{} = actions) do
    %{
      state_delta: actions.state_delta,
      transfer_to_agent: actions.transfer_to_agent,
      escalate: actions.escalate
    }
  end

  defp serialize_actions(other), do: other

  # Sanitize values that may not be JSON-encodable (tuples, pids, etc.)
  defp sanitize_for_json(nil), do: nil
  defp sanitize_for_json(val) when is_binary(val), do: val
  defp sanitize_for_json(val) when is_number(val), do: val
  defp sanitize_for_json(val) when is_boolean(val), do: val
  defp sanitize_for_json(val) when is_atom(val), do: to_string(val)
  defp sanitize_for_json(val) when is_list(val), do: Enum.map(val, &sanitize_for_json/1)

  defp sanitize_for_json(val) when is_map(val) do
    Map.new(val, fn {k, v} -> {to_string(k), sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(val) when is_tuple(val) do
    val |> Tuple.to_list() |> Enum.map(&sanitize_for_json/1)
  end

  defp sanitize_for_json(val), do: inspect(val)
end
