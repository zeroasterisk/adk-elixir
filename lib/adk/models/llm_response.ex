defmodule ADK.Models.LlmResponse do
  @moduledoc """
  LLM response struct that provides the first candidate response from the
  model if available. Otherwise, returns error code and message.
  """

  defstruct model_version: nil,
            content: nil,
            grounding_metadata: nil,
            partial: nil,
            turn_complete: nil,
            finish_reason: nil,
            error_code: nil,
            error_message: nil,
            interrupted: nil,
            custom_metadata: nil,
            usage_metadata: nil,
            live_session_resumption_update: nil,
            input_transcription: nil,
            output_transcription: nil,
            avg_logprobs: nil,
            logprobs_result: nil,
            cache_metadata: nil,
            citation_metadata: nil,
            interaction_id: nil

  @type t :: %__MODULE__{}

  @doc """
  Creates an LlmResponse from a GenerateContentResponse (map or struct).
  """
  def create(generate_content_response) when is_map(generate_content_response) do
    get_field = fn map, atom_key, string_key ->
      if is_map(map) do
        Map.get(map, atom_key, Map.get(map, string_key))
      else
        nil
      end
    end

    usage_metadata = get_field.(generate_content_response, :usage_metadata, "usageMetadata")
    model_version = get_field.(generate_content_response, :model_version, "modelVersion")
    candidates = get_field.(generate_content_response, :candidates, "candidates") || []

    if length(candidates) > 0 do
      candidate = hd(candidates)

      content = get_field.(candidate, :content, "content")
      finish_reason = get_field.(candidate, :finish_reason, "finishReason")
      finish_message = get_field.(candidate, :finish_message, "finishMessage")
      grounding_metadata = get_field.(candidate, :grounding_metadata, "groundingMetadata")
      citation_metadata = get_field.(candidate, :citation_metadata, "citationMetadata")
      avg_logprobs = get_field.(candidate, :avg_logprobs, "avgLogprobs")
      logprobs_result = get_field.(candidate, :logprobs_result, "logprobsResult")

      parts = if content, do: get_field.(content, :parts, "parts"), else: nil

      if (content && parts) || finish_reason == "STOP" || finish_reason == :STOP do
        %__MODULE__{
          content: content,
          grounding_metadata: grounding_metadata,
          usage_metadata: usage_metadata,
          finish_reason: finish_reason,
          citation_metadata: citation_metadata,
          avg_logprobs: avg_logprobs,
          logprobs_result: logprobs_result,
          model_version: model_version
        }
      else
        %__MODULE__{
          error_code: finish_reason,
          error_message: finish_message,
          usage_metadata: usage_metadata,
          finish_reason: finish_reason,
          citation_metadata: citation_metadata,
          avg_logprobs: avg_logprobs,
          logprobs_result: logprobs_result,
          model_version: model_version
        }
      end
    else
      prompt_feedback = get_field.(generate_content_response, :prompt_feedback, "promptFeedback")

      if prompt_feedback do
        block_reason = get_field.(prompt_feedback, :block_reason, "blockReason")

        block_reason_message =
          get_field.(prompt_feedback, :block_reason_message, "blockReasonMessage")

        %__MODULE__{
          error_code: block_reason,
          error_message: block_reason_message,
          usage_metadata: usage_metadata,
          model_version: model_version
        }
      else
        %__MODULE__{
          error_code: "UNKNOWN_ERROR",
          error_message: "Unknown error.",
          usage_metadata: usage_metadata,
          model_version: model_version
        }
      end
    end
  end
end
