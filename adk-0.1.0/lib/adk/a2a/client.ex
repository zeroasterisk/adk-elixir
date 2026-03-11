defmodule ADK.A2A.Client do
  @moduledoc """
  A2A protocol client — delegates to `A2A.Client` from the
  [a2a](https://github.com/zeroasterisk/a2a-elixir) package.

  Kept for backward compatibility.
  """

  @doc "Fetch the Agent Card from a remote A2A server."
  @spec get_agent_card(String.t()) :: {:ok, map()} | {:error, term()}
  def get_agent_card(base_url) do
    case A2A.Client.get_agent_card(base_url) do
      {:ok, %A2A.AgentCard{} = card} -> {:ok, A2A.AgentCard.to_map(card)}
      error -> error
    end
  end

  @doc "Send a task to a remote A2A agent."
  @spec send_task(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate send_task(base_url, message, opts \\ []), to: A2A.Client

  @doc "Get a task's status and history from a remote A2A agent."
  @spec get_task(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_task(base_url, task_id), do: A2A.Client.get_task(base_url, task_id)

  @doc "Cancel a task on a remote A2A agent."
  @spec cancel_task(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel_task(base_url, task_id), do: A2A.Client.cancel_task(base_url, task_id)
end
