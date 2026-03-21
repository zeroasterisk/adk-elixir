if Code.ensure_loaded?(A2A.AgentCard) do
defmodule ADK.A2A.Client do
  @moduledoc """
  A2A protocol client — delegates to `A2A.Client` from the
  [a2a](https://github.com/zeroasterisk/a2a-elixir) package.

  Updated for A2A v1.0.
  """

  @doc "Fetch the Agent Card from a remote A2A server."
  @spec get_agent_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_agent_card(base_url, opts \\ []) do
    case A2A.Client.discover(base_url, opts) do
      {:ok, %A2A.AgentCard{} = card} -> {:ok, agent_card_to_map(card)}
      error -> error
    end
  end

  @doc "Send a message (task) to a remote A2A agent."
  @spec send_task(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_task(base_url, message, opts \\ []) do
    A2A.Client.send_message(base_url, message, opts)
  end

  @doc "Get a task's status and history from a remote A2A agent."
  @spec get_task(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_task(base_url, task_id, opts \\ []), do: A2A.Client.get_task(base_url, task_id, opts)

  @doc "Cancel a task on a remote A2A agent."
  @spec cancel_task(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel_task(base_url, task_id, opts \\ []), do: A2A.Client.cancel_task(base_url, task_id, opts)

  # -- Streaming --

  @doc "Send a streaming message to a remote A2A agent."
  @spec send_streaming_message(String.t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def send_streaming_message(base_url, message, opts \\ []) do
    A2A.Client.stream_message(base_url, message, opts)
  end

  # -- Helpers --

  defp agent_card_to_map(%A2A.AgentCard{} = card) do
    A2A.JSON.encode_agent_card(card)
  end
end
else
  defmodule ADK.A2A.Client do
    @moduledoc "Requires {:a2a, \"~> 0.2\"} optional dependency. Install it to enable A2A protocol support."
  end
end
