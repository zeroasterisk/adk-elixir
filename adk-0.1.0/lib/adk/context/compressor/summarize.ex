defmodule ADK.Context.Compressor.Summarize do
  @moduledoc """
  Summarization strategy — uses an LLM to condense older messages.

  Keeps the last N messages verbatim and summarizes everything before them
  into a single condensed message.

  ## Options

    * `:keep_recent` - Number of recent messages to keep verbatim (default: 10)
    * `:summary_instruction` - Custom prompt for summarization (optional)

  ## Context

  Requires `:model` in the context map to know which LLM to call.

  ## Examples

      {:ok, compressed} = Summarize.compress(messages, [keep_recent: 5],
        %{model: "gemini-2.0-flash"})
  """

  @behaviour ADK.Context.Compressor

  @default_keep_recent 10
  @default_summary_instruction """
  Summarize the following conversation history into a concise paragraph.
  Preserve key facts, decisions, and context that would be needed to continue
  the conversation. Be brief but complete.
  """

  @impl true
  def compress(messages, opts \\ [], context \\ %{}) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    model = Map.get(context, :model)

    if is_nil(model) do
      {:error, :no_model_for_summarization}
    else
      {system_msgs, non_system_msgs} =
        Enum.split_with(messages, fn msg -> msg.role == :system end)

      if length(non_system_msgs) <= keep_recent do
        {:ok, messages}
      else
        {old_msgs, recent_msgs} = Enum.split(non_system_msgs, length(non_system_msgs) - keep_recent)
        do_summarize(system_msgs, old_msgs, recent_msgs, model, opts)
      end
    end
  end

  defp do_summarize(system_msgs, old_msgs, recent_msgs, model, opts) do
    instruction =
      Keyword.get(opts, :summary_instruction, @default_summary_instruction)

    conversation_text =
      old_msgs
      |> Enum.map(fn msg ->
        role = to_string(msg.role)
        parts_text = Enum.map_join(msg.parts, "\n", fn
          %{text: t} -> t
          other -> inspect(other)
        end)
        "#{role}: #{parts_text}"
      end)
      |> Enum.join("\n")

    summary_request = %{
      model: model,
      instruction: instruction,
      messages: [
        %{role: :user, parts: [%{text: conversation_text}]}
      ],
      tools: []
    }

    case ADK.LLM.generate(model, summary_request) do
      {:ok, %{content: %{parts: [%{text: summary_text} | _]}}} ->
        summary_msg = %{
          role: :user,
          parts: [%{text: "[Summary of earlier conversation]\n#{summary_text}"}]
        }

        {:ok, system_msgs ++ [summary_msg | recent_msgs]}

      {:ok, _} ->
        # Fallback: if we can't extract text, just truncate
        {:ok, system_msgs ++ recent_msgs}

      {:error, _} = err ->
        err
    end
  end
end
