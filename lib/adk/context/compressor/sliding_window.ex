defmodule ADK.Context.Compressor.SlidingWindow do
  @moduledoc """
  Sliding window strategy — keeps system messages plus the last N messages,
  with awareness of function call/response pairs.

  Unlike simple truncation, this strategy ensures that function responses
  are never orphaned from their corresponding function calls. If a split
  point would separate a function call from its response, the window is
  expanded to include the full pair.

  This mirrors Python ADK's `ContextFilterPlugin` with invocation-aware
  splitting.

  ## Options

    * `:max_messages` - Maximum number of non-system messages to keep (default: 20)
    * `:invocations` - If set, keep the last N user invocations instead of
      counting individual messages. An invocation starts with a user message
      and includes all subsequent model/tool turns until the next user message.
      Takes precedence over `:max_messages`.

  ## Examples

      {:ok, compressed} = SlidingWindow.compress(messages, max_messages: 10)

      # Keep last 3 user invocations (with all their tool calls)
      {:ok, compressed} = SlidingWindow.compress(messages, invocations: 3)
  """

  @behaviour ADK.Context.Compressor

  @default_max_messages 20

  @impl true
  @spec compress([ADK.Context.Compressor.message()], keyword(), map()) ::
          {:ok, [ADK.Context.Compressor.message()]} | {:error, term()}
  def compress(messages, opts \\ [], _context \\ %{}) do
    {system_msgs, non_system_msgs} =
      Enum.split_with(messages, fn msg -> msg.role == :system end)

    compressed =
      case Keyword.get(opts, :invocations) do
        nil ->
          max = Keyword.get(opts, :max_messages, @default_max_messages)
          split_and_keep(non_system_msgs, max)

        n when is_integer(n) and n > 0 ->
          keep_last_n_invocations(non_system_msgs, n)
      end

    {:ok, system_msgs ++ compressed}
  end

  defp split_and_keep(messages, max) when length(messages) <= max, do: messages

  defp split_and_keep(messages, max) do
    split_index = length(messages) - max
    split_index = adjust_for_function_pairs(messages, split_index)
    Enum.drop(messages, split_index)
  end

  defp keep_last_n_invocations(messages, n) do
    invocation_starts = get_invocation_start_indices(messages)

    if length(invocation_starts) <= n do
      messages
    else
      split_index = Enum.at(invocation_starts, length(invocation_starts) - n)
      split_index = adjust_for_function_pairs(messages, split_index)
      Enum.drop(messages, split_index)
    end
  end

  defp get_invocation_start_indices(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce({[], false}, fn {msg, idx}, {indices, prev_was_user} ->
      is_human_user = msg.role == :user && !has_function_response?(msg)

      indices =
        if is_human_user && !prev_was_user do
          [idx | indices]
        else
          indices
        end

      {indices, is_human_user}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp has_function_response?(%{parts: parts}) when is_list(parts) do
    Enum.any?(parts, fn
      %{function_response: fr} when not is_nil(fr) -> true
      _ -> false
    end)
  end

  defp has_function_response?(_), do: false

  # Walk backward from split_index to ensure we don't orphan function responses
  defp adjust_for_function_pairs(messages, split_index) do
    # Collect function response IDs from kept messages (split_index..)
    # If any response lacks its call, expand the window
    kept = Enum.drop(messages, split_index)

    needed_call_ids =
      kept
      |> Enum.flat_map(fn msg ->
        (msg[:parts] || [])
        |> Enum.flat_map(fn
          %{function_response: %{id: id}} when not is_nil(id) -> [id]
          _ -> []
        end)
      end)
      |> MapSet.new()

    provided_call_ids =
      kept
      |> Enum.flat_map(fn msg ->
        (msg[:parts] || [])
        |> Enum.flat_map(fn
          %{function_call: %{id: id}} when not is_nil(id) -> [id]
          _ -> []
        end)
      end)
      |> MapSet.new()

    missing = MapSet.difference(needed_call_ids, provided_call_ids)

    if MapSet.size(missing) == 0 do
      split_index
    else
      # Expand window to include missing calls
      find_expanded_index(messages, split_index, missing)
    end
  end

  defp find_expanded_index(_messages, 0, _missing), do: 0

  defp find_expanded_index(messages, index, missing) do
    msg = Enum.at(messages, index - 1)

    call_ids_here =
      (msg[:parts] || [])
      |> Enum.flat_map(fn
        %{function_call: %{id: id}} when not is_nil(id) -> [id]
        _ -> []
      end)
      |> MapSet.new()

    remaining = MapSet.difference(missing, call_ids_here)

    if MapSet.size(remaining) == 0 do
      index - 1
    else
      find_expanded_index(messages, index - 1, remaining)
    end
  end
end
