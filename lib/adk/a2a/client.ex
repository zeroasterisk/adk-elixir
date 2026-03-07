defmodule ADK.A2A.Client do
  @moduledoc """
  A2A protocol client — fetch agent cards and send tasks to remote agents.
  """

  @doc "Fetch the Agent Card from a remote A2A server."
  @spec get_agent_card(String.t()) :: {:ok, map()} | {:error, term()}
  def get_agent_card(base_url) do
    url = String.trim_trailing(base_url, "/") <> "/.well-known/agent.json"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send a task to a remote A2A agent.

  ## Options
    - `:session_id` — optional session identifier
    - `:task_id` — optional task identifier
  """
  @spec send_task(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_task(base_url, message, opts \\ []) do
    rpc_request(base_url, "tasks/send", %{
      "message" => %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => message}]
      },
      "sessionId" => opts[:session_id],
      "id" => opts[:task_id]
    })
  end

  @doc "Get a task's status and history from a remote A2A agent."
  @spec get_task(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_task(base_url, task_id) do
    rpc_request(base_url, "tasks/get", %{"id" => task_id})
  end

  @doc "Cancel a task on a remote A2A agent."
  @spec cancel_task(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel_task(base_url, task_id) do
    rpc_request(base_url, "tasks/cancel", %{"id" => task_id})
  end

  defp rpc_request(base_url, method, params) do
    url = String.trim_trailing(base_url, "/") <> "/"
    id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
