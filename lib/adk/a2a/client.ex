if Code.ensure_loaded?(A2A.AgentCard) and function_exported?(A2A.AgentCard, :new, 1) do
defmodule ADK.A2A.Client do
  @moduledoc """
  A2A protocol client — delegates to `A2A.Client` from the
  [a2a](https://github.com/zeroasterisk/a2a-elixir) package.

  Updated for A2A v1.0.
  """

  @doc "Fetch the Agent Card from a remote A2A server."
  @spec get_agent_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_agent_card(base_url, opts \\ []) do
    case A2A.Client.get_agent_card(base_url, opts) do
      {:ok, %A2A.AgentCard{} = card} -> {:ok, A2A.AgentCard.to_map(card)}
      error -> error
    end
  end

  @doc "Fetch the Extended Agent Card from a remote A2A server."
  @spec get_extended_agent_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_extended_agent_card(base_url, opts \\ []) do
    case A2A.Client.get_extended_agent_card(base_url, opts) do
      {:ok, %A2A.AgentCard{} = card} -> {:ok, A2A.AgentCard.to_map(card)}
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

  @doc "List tasks from a remote A2A agent."
  @spec list_tasks(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_tasks(base_url, opts \\ []), do: A2A.Client.list_tasks(base_url, opts)

  # -- Push Notification CRUD --

  @doc "Set push notification config for a task."
  @spec set_push_notification_config(String.t(), A2A.PushNotificationConfig.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_push_notification_config(base_url, config, opts \\ []) do
    case A2A.Client.set_push_notification_config(base_url, config, opts) do
      {:ok, %A2A.PushNotificationConfig{} = c} -> {:ok, A2A.PushNotificationConfig.to_map(c)}
      error -> error
    end
  end

  @doc "Get push notification config for a task."
  @spec get_push_notification_config(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_push_notification_config(base_url, task_id, opts \\ []) do
    case A2A.Client.get_push_notification_config(base_url, task_id, opts) do
      {:ok, %A2A.PushNotificationConfig{} = c} -> {:ok, A2A.PushNotificationConfig.to_map(c)}
      error -> error
    end
  end

  @doc "List push notification configs."
  @spec list_push_notification_configs(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_push_notification_configs(base_url, opts \\ []) do
    case A2A.Client.list_push_notification_configs(base_url, opts) do
      {:ok, configs} when is_list(configs) ->
        {:ok, Enum.map(configs, &A2A.PushNotificationConfig.to_map/1)}
      error -> error
    end
  end

  @doc "Delete push notification config for a task."
  @spec delete_push_notification_config(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete_push_notification_config(base_url, task_id, opts \\ []) do
    A2A.Client.delete_push_notification_config(base_url, task_id, opts)
  end

  # -- Streaming --

  @doc "Send a streaming message to a remote A2A agent."
  @spec send_streaming_message(String.t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def send_streaming_message(base_url, message, opts \\ []) do
    A2A.Client.send_streaming_message(base_url, message, opts)
  end
end
else
  defmodule ADK.A2A.Client do
    @moduledoc "Requires {:a2a, \"~> 0.2\"} optional dependency. Install it to enable A2A protocol support."
  end
end
