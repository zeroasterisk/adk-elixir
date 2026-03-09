defmodule ADK.Context.Compressor.Truncate do
  @moduledoc """
  Simple truncation strategy — keeps system messages and the last N messages.

  ## Options

    * `:max_messages` - Maximum number of non-system messages to keep (default: 20)
    * `:keep_system` - Whether to always preserve system-role messages (default: true)

  ## Examples

      {:ok, compressed} = Truncate.compress(messages, max_messages: 10)
  """

  @behaviour ADK.Context.Compressor

  @default_max_messages 20

  @impl true
  def compress(messages, opts \\ [], _context \\ %{}) do
    max = Keyword.get(opts, :max_messages, @default_max_messages)
    keep_system = Keyword.get(opts, :keep_system, true)

    {system_msgs, non_system_msgs} =
      if keep_system do
        Enum.split_with(messages, fn msg -> msg.role == :system end)
      else
        {[], messages}
      end

    kept = Enum.take(non_system_msgs, -max)
    {:ok, system_msgs ++ kept}
  end
end
