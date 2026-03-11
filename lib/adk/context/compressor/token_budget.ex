defmodule ADK.Context.Compressor.TokenBudget do
  @moduledoc """
  Token budget compaction strategy — keeps conversation history within a
  configurable token limit.

  Unlike message-count-based strategies (Truncate, SlidingWindow), this
  compressor estimates the actual token footprint of history and trims older
  messages to fit within the budget. This mirrors the Python ADK's approach of
  counting characters ÷ 4 as a rough token estimate.

  ## Strategy

  1. System messages and a configurable number of recent messages are always kept
     (they are deducted from the budget first).
  2. Older messages are then added back newest-first until the remaining budget
     is exhausted.
  3. Messages that don't fit are dropped.

  This preserves the most recent context while respecting token limits.

  ## Options

    * `:token_budget` - Maximum tokens for message history (required)
    * `:chars_per_token` - Characters per token for estimation (default: 4,
      matching Python ADK's heuristic)
    * `:keep_recent` - Minimum number of recent non-system messages to always
      keep verbatim, regardless of budget (default: 2)
    * `:keep_system` - Whether to always preserve system-role messages
      (default: true)

  ## Examples

      {:ok, compressed} = TokenBudget.compress(messages, token_budget: 4000)

      # 8k budget, GPT-style tighter token estimate
      {:ok, compressed} = TokenBudget.compress(messages,
        token_budget: 8000,
        chars_per_token: 3,
        keep_recent: 5
      )

  ## Integration with maybe_compress/2

  To use via `ADK.Context.Compressor.maybe_compress/2`, set `threshold: 0` so
  it always runs (the strategy itself enforces the budget):

      opts = [
        strategy: {ADK.Context.Compressor.TokenBudget, [token_budget: 4000]},
        threshold: 0
      ]
      messages = ADK.Context.Compressor.maybe_compress(messages, opts)
  """

  @behaviour ADK.Context.Compressor

  @default_chars_per_token 4
  @default_keep_recent 2

  @impl true
  def compress(messages, opts \\ [], _context \\ %{}) do
    token_budget = Keyword.fetch!(opts, :token_budget)
    chars_per_token = Keyword.get(opts, :chars_per_token, @default_chars_per_token)
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    keep_system = Keyword.get(opts, :keep_system, true)

    {system_msgs, non_system_msgs} =
      if keep_system do
        Enum.split_with(messages, fn msg -> msg.role == :system end)
      else
        {[], messages}
      end

    # Partition: always-kept recent messages vs. older candidates for trimming
    {old_msgs, recent_msgs} =
      if length(non_system_msgs) <= keep_recent do
        {[], non_system_msgs}
      else
        Enum.split(non_system_msgs, length(non_system_msgs) - keep_recent)
      end

    # Deduct fixed cost (system + recent) from budget
    fixed_tokens = estimate_tokens(system_msgs ++ recent_msgs, chars_per_token)
    available_tokens = token_budget - fixed_tokens

    if available_tokens <= 0 or old_msgs == [] do
      # No room for older messages, or nothing to trim
      {:ok, system_msgs ++ recent_msgs}
    else
      # Greedily include older messages newest-first until budget exhausted
      included_old = fill_from_newest(old_msgs, available_tokens, chars_per_token)
      {:ok, system_msgs ++ included_old ++ recent_msgs}
    end
  end

  @doc """
  Estimate the token count for a list of messages using a character-based
  heuristic. Defaults to 4 chars per token, matching the Python ADK.

  ## Examples

      iex> msgs = [%{role: :user, parts: [%{text: "hello world"}]}]
      iex> ADK.Context.Compressor.TokenBudget.estimate_tokens(msgs)
      2
  """
  @spec estimate_tokens([map()], pos_integer()) :: non_neg_integer()
  def estimate_tokens(messages, chars_per_token \\ @default_chars_per_token) do
    total_chars =
      Enum.reduce(messages, 0, fn msg, acc ->
        acc + count_message_chars(msg)
      end)

    div(total_chars, max(chars_per_token, 1))
  end

  @doc """
  Estimate token count for a single message.
  """
  @spec estimate_message_tokens(map(), pos_integer()) :: non_neg_integer()
  def estimate_message_tokens(message, chars_per_token \\ @default_chars_per_token) do
    div(count_message_chars(message), max(chars_per_token, 1))
  end

  # --- Private helpers ---

  # Count total characters in a message's text parts
  defp count_message_chars(%{parts: parts}) when is_list(parts) do
    Enum.reduce(parts, 0, fn
      %{text: text}, acc when is_binary(text) -> acc + byte_size(text)
      _, acc -> acc
    end)
  end

  defp count_message_chars(_msg), do: 0

  # Starting from the newest old message, include as many as fit within budget
  # Returns messages in original (oldest-first) order.
  defp fill_from_newest(old_msgs, available_tokens, chars_per_token) do
    old_msgs
    |> Enum.reverse()
    |> Enum.reduce_while({available_tokens, []}, fn msg, {remaining, acc} ->
      msg_tokens = estimate_message_tokens(msg, chars_per_token)

      if msg_tokens <= remaining do
        {:cont, {remaining - msg_tokens, [msg | acc]}}
      else
        # Stop: this message (and all older ones) won't fit
        {:halt, {remaining, acc}}
      end
    end)
    |> elem(1)
  end
end
