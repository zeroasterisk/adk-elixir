defmodule ADK.Context.Compressor do
  @moduledoc """
  Behaviour for context compression strategies.

  Context compression reduces the number of messages/tokens sent to the LLM
  when conversation history grows too large. Strategies implement this behaviour
  to provide different compression approaches.

  ## Configuration

  Compression can be configured on the agent or via `RunConfig`:

      agent = LlmAgent.new(
        name: "bot",
        model: "gemini-flash-latest",
        instruction: "Help",
        context_compressor: {ADK.Context.Compressor.Truncate, max_messages: 20}
      )

  Or triggered automatically when message count exceeds a threshold.
  """

  @type message :: %{role: atom(), parts: [map()]}

  @doc """
  Compress a list of messages, returning a shorter list.

  The `opts` keyword list contains strategy-specific configuration.
  The `context` map may include `:model` and `:instruction` for strategies
  that need to call the LLM (e.g., summarization).
  """
  @callback compress(messages :: [message()], opts :: keyword(), context :: map()) ::
              {:ok, [message()]} | {:error, term()}

  @doc """
  Apply compression to messages if they exceed the configured threshold.

  Returns the original messages if no compressor is configured or if
  the message count is below the threshold.
  """
  @spec maybe_compress([message()], keyword() | nil) :: [message()]
  def maybe_compress(messages, nil), do: messages
  def maybe_compress(messages, []), do: messages

  def maybe_compress(messages, opts) when is_list(opts) do
    {strategy, strategy_opts} =
      case Keyword.fetch!(opts, :strategy) do
        {mod, sopts} when is_atom(mod) -> {mod, sopts}
        mod when is_atom(mod) -> {mod, []}
      end

    threshold = Keyword.get(opts, :threshold, 50)

    if length(messages) > threshold do
      context = Keyword.get(opts, :context, %{})

      case strategy.compress(messages, strategy_opts, context) do
        {:ok, compressed} ->
          # Store compaction event in session if session_pid is available
          session_pid = Keyword.get(opts, :session_pid)
          store_compaction_event(session_pid, messages, compressed)
          compressed

        {:error, _reason} ->
          messages
      end
    else
      messages
    end
  end

  @doc """
  Create a compaction event summarizing what was compressed.

  The event has author `"system:compaction"` so it can be identified
  during session reload and content assembly.
  """
  @spec compaction_event(non_neg_integer(), non_neg_integer()) :: ADK.Event.t()
  def compaction_event(original_count, compressed_count) do
    ADK.Event.new(%{
      author: "system:compaction",
      content: %{
        parts: [
          %{
            text:
              "[Context compacted: #{original_count} messages compressed to #{compressed_count} messages]"
          }
        ]
      }
    })
  end

  defp store_compaction_event(nil, _original, _compressed), do: :ok

  defp store_compaction_event(session_pid, original, compressed) do
    event = compaction_event(length(original), length(compressed))

    try do
      ADK.Session.append_event(session_pid, event)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
