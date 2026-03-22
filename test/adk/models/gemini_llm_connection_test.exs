defmodule ADK.Models.GeminiLlmConnectionTest do
  @moduledoc """
  Parity tests for Python's tests/unittests/models/test_gemini_llm_connection.py
  Since ADK Elixir handles LLM connections differently (via Req to the REST API directly
  in ADK.LLM.Gemini without a stateful connection object for now), these tests are
  pending/skipped until Live API streaming support is added.
  """
  use ExUnit.Case, async: true

  @tag :skip
  test "test_send_realtime_default_behavior" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_history" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_content_text" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_content_function_response" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_close" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_transcript_finished" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_usage_metadata_and_server_content" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_transcript_finished_on_interrupt" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_transcript_finished_on_generation_complete" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_transcript_finished_on_turn_complete" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_handles_input_transcription_fragments" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_handles_output_transcription_fragments" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_history_filters_audio" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_history_keeps_image_data" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_history_mixed_content_filters_only_audio" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_history_all_audio_content_not_sent" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_history_empty_history_not_sent" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_send_history_filters_various_audio_mime_types" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_grounding_metadata_standalone" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_grounding_metadata_with_content" do
    flunk("Not implemented")
  end

  @tag :skip
  test "test_receive_tool_call_and_grounding_metadata_with_native_audio" do
    flunk("Not implemented")
  end
end
