defmodule ADK.Artifact.InMemory do
  @moduledoc """
  In-memory artifact store backed by an Agent process.

  Artifacts are stored in a nested map keyed by
  `{app_name, user_id, session_id, filename}` with a list of versions
  (newest first).

  ## Usage

      {:ok, pid} = ADK.Artifact.InMemory.start_link()
      runner = ADK.Runner.new(app_name: "app", agent: agent, artifact_service: {ADK.Artifact.InMemory, pid: pid})
  """

  @behaviour ADK.Artifact.Store

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    agent_opts = if name, do: [name: name], else: []
    Agent.start_link(fn -> %{} end, agent_opts)
  end

  defp agent(opts) do
    Keyword.get(opts, :pid) || Keyword.get(opts, :name) || __MODULE__
  end

  @impl true
  def save(app_name, user_id, session_id, filename, artifact, opts \\ []) do
    pid = agent(opts)
    key = {app_name, user_id, session_id, filename}

    version =
      Agent.get_and_update(pid, fn state ->
        versions = Map.get(state, key, [])
        new_version = length(versions)
        {new_version, Map.put(state, key, [artifact | versions])}
      end)

    {:ok, version}
  end

  @impl true
  def load(app_name, user_id, session_id, filename, opts \\ []) do
    pid = agent(opts)
    key = {app_name, user_id, session_id, filename}
    version = Keyword.get(opts, :version)

    Agent.get(pid, fn state ->
      case Map.get(state, key) do
        nil ->
          :not_found

        [] ->
          :not_found

        versions ->
          if version do
            # versions are stored newest-first, so index from end
            idx = length(versions) - 1 - version

            if idx >= 0 and idx < length(versions) do
              {:ok, Enum.at(versions, idx)}
            else
              :not_found
            end
          else
            {:ok, hd(versions)}
          end
      end
    end)
  end

  @impl true
  def list(app_name, user_id, session_id, opts \\ []) do
    pid = agent(opts)
    prefix = {app_name, user_id, session_id}

    filenames =
      Agent.get(pid, fn state ->
        state
        |> Map.keys()
        |> Enum.filter(fn {a, u, s, _f} -> {a, u, s} == prefix end)
        |> Enum.map(fn {_a, _u, _s, f} -> f end)
        |> Enum.sort()
      end)

    {:ok, filenames}
  end

  @impl true
  def delete(app_name, user_id, session_id, filename, opts \\ []) do
    pid = agent(opts)
    key = {app_name, user_id, session_id, filename}
    Agent.update(pid, &Map.delete(&1, key))
    :ok
  end
end
