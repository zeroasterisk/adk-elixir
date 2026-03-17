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

defmodule ADK.Phoenix.WebServerClient do
  @moduledoc """
  HTTP client for interacting with the ADK web server for conformance tests.

  Elixir parity for Python ADK's `AdkWebServerClient` — used to drive
  `ADK.Phoenix.WebRouter` (or the Python `adk web` server) in conformance
  and integration test scenarios.

  ## Usage

      client = ADK.Phoenix.WebServerClient.new()
      {:ok, session} = ADK.Phoenix.WebServerClient.create_session(client,
        app_name: "my_app", user_id: "alice")

      request = %{
        app_name: "my_app",
        user_id: "alice",
        session_id: session["id"],
        new_message: %{role: "user", parts: [%{text: "Hello"}]}
      }

      {:ok, events} = ADK.Phoenix.WebServerClient.run_agent(client, request)

      ADK.Phoenix.WebServerClient.close(client)
  """

  require Logger

  @default_base_url "http://127.0.0.1:8000"
  @default_timeout 30_000

  @type t :: %__MODULE__{
          base_url: String.t(),
          timeout: non_neg_integer()
        }

  defstruct [:base_url, :timeout]

  @doc """
  Create a new client.

  ## Options

    * `:base_url` — Base URL of the ADK web server (default: `#{@default_base_url}`)
    * `:timeout` — Request timeout in milliseconds (default: #{@default_timeout})
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url =
      opts
      |> Keyword.get(:base_url, @default_base_url)
      |> String.trim_trailing("/")

    timeout = Keyword.get(opts, :timeout, @default_timeout)

    %__MODULE__{base_url: base_url, timeout: timeout}
  end

  @doc """
  Close the client. No-op for the stateless Req-based implementation; included
  for API parity with Python's `await client.close()`.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------
  # Session API
  # ---------------------------------------------------------------------------

  @doc """
  Get a session by ID.

  Returns `{:ok, session_map}` or `{:error, reason}`.
  """
  @spec get_session(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_session(%__MODULE__{} = client, opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    user_id = Keyword.fetch!(opts, :user_id)
    session_id = Keyword.fetch!(opts, :session_id)

    path = "/apps/#{app_name}/users/#{user_id}/sessions/#{session_id}"

    case req_get(client, path) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create a new session.

  Returns `{:ok, session_map}` or `{:error, reason}`.
  """
  @spec create_session(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_session(%__MODULE__{} = client, opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    user_id = Keyword.fetch!(opts, :user_id)
    state = Keyword.get(opts, :state, %{})

    path = "/apps/#{app_name}/users/#{user_id}/sessions"

    case req_post(client, path, %{state: state}) do
      {:ok, %{status: status, body: body}} when status in [200, 201] -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete a session.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec delete_session(t(), keyword()) :: :ok | {:error, term()}
  def delete_session(%__MODULE__{} = client, opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    user_id = Keyword.fetch!(opts, :user_id)
    session_id = Keyword.fetch!(opts, :session_id)

    path = "/apps/#{app_name}/users/#{user_id}/sessions/#{session_id}"

    case req_delete(client, path) do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update a session's state delta.

  Returns `{:ok, session_map}` or `{:error, reason}`.
  """
  @spec update_session(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_session(%__MODULE__{} = client, opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    user_id = Keyword.fetch!(opts, :user_id)
    session_id = Keyword.fetch!(opts, :session_id)
    state_delta = Keyword.fetch!(opts, :state_delta)

    path = "/apps/#{app_name}/users/#{user_id}/sessions/#{session_id}"

    case req_patch(client, path, %{state_delta: state_delta}) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Agent execution
  # ---------------------------------------------------------------------------

  @doc """
  Run an agent and return all streamed events.

  Sends a `POST /run_sse` request and collects SSE events into a list.
  Returns `{:ok, [event_map]}` or `{:error, reason}`.

  For large/long-running agents, consider implementing a streaming variant
  yourself using `Req.get/2` with `into: :self`.
  """
  @spec run_agent(t(), map()) :: {:ok, [map()]} | {:error, term()}
  def run_agent(%__MODULE__{} = client, request) when is_map(request) do
    url = client.base_url <> "/run_sse"

    case Req.post(url,
           json: request,
           receive_timeout: client.timeout,
           headers: [{"accept", "text/event-stream"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        parse_sse_body(body)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Artifact metadata
  # ---------------------------------------------------------------------------

  @doc """
  Get metadata for a specific artifact version.

  Returns `{:ok, artifact_version_map}` or `{:error, reason}`.
  """
  @spec get_artifact_version_metadata(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_artifact_version_metadata(%__MODULE__{} = client, opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    user_id = Keyword.fetch!(opts, :user_id)
    session_id = Keyword.fetch!(opts, :session_id)
    artifact_name = Keyword.fetch!(opts, :artifact_name)
    version = Keyword.fetch!(opts, :version)

    path =
      "/apps/#{app_name}/users/#{user_id}/sessions/#{session_id}" <>
        "/artifacts/#{artifact_name}/versions/#{version}/metadata"

    case req_get(client, path) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List metadata for all versions of an artifact.

  Returns `{:ok, [artifact_version_map]}` or `{:error, reason}`.
  """
  @spec list_artifact_versions_metadata(t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_artifact_versions_metadata(%__MODULE__{} = client, opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    user_id = Keyword.fetch!(opts, :user_id)
    session_id = Keyword.fetch!(opts, :session_id)
    artifact_name = Keyword.fetch!(opts, :artifact_name)

    path =
      "/apps/#{app_name}/users/#{user_id}/sessions/#{session_id}" <>
        "/artifacts/#{artifact_name}/versions/metadata"

    case req_get(client, path) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Version
  # ---------------------------------------------------------------------------

  @doc """
  Get version data from the server.

  Returns `{:ok, version_map}` or `{:error, reason}`.
  """
  @spec get_version_data(t()) :: {:ok, map()} | {:error, term()}
  def get_version_data(%__MODULE__{} = client) do
    case req_get(client, "/version") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp req_get(%__MODULE__{base_url: base_url, timeout: timeout}, path) do
    Req.get(base_url <> path, receive_timeout: timeout, decode_body: true)
  end

  defp req_post(%__MODULE__{base_url: base_url, timeout: timeout}, path, body) do
    Req.post(base_url <> path, json: body, receive_timeout: timeout)
  end

  defp req_delete(%__MODULE__{base_url: base_url, timeout: timeout}, path) do
    Req.delete(base_url <> path, receive_timeout: timeout)
  end

  defp req_patch(%__MODULE__{base_url: base_url, timeout: timeout}, path, body) do
    Req.patch(base_url <> path, json: body, receive_timeout: timeout)
  end

  @doc false
  def parse_sse_body(body) when is_binary(body) do
    events =
      body
      |> String.split("\n")
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        cond do
          String.starts_with?(line, "data:") ->
            data = line |> String.slice(5..-1//1) |> String.trim()

            if data == "" do
              {:cont, {:ok, acc}}
            else
              case Jason.decode(data) do
                {:ok, %{"error" => msg}} ->
                  {:halt, {:error, msg}}

                {:ok, event} ->
                  {:cont, {:ok, [event | acc]}}

                {:error, _} ->
                  Logger.debug("SSE: could not parse line: #{inspect(line)}")
                  {:cont, {:ok, acc}}
              end
            end

          true ->
            {:cont, {:ok, acc}}
        end
      end)

    case events do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  def parse_sse_body(_), do: {:ok, []}
end
