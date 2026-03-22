# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Flows.LlmFlows.TranscriptionManagerTest do
  use ExUnit.Case, async: true

  alias ADK.Event
  alias ADK.Context
  alias ADK.Flows.LlmFlows.TranscriptionManager

  setup do
    agent = %ADK.Agent.LlmAgent{name: "test_agent"}
    ctx = %Context{invocation_id: "test-inv-1", agent: agent}
    %{ctx: ctx}
  end

  test "handle_input_transcription/2", %{ctx: ctx} do
    transcription = %{text: "Hello from user"}
    event = TranscriptionManager.handle_input_transcription(ctx, transcription)

    assert event.author == "user"
    assert event.invocation_id == "test-inv-1"
    assert event.input_transcription == transcription
    assert event.output_transcription == nil
    # No session service append is mocked because the python version assert_not_called
  end

  test "handle_output_transcription/2", %{ctx: ctx} do
    transcription = %{text: "Hello from model"}
    event = TranscriptionManager.handle_output_transcription(ctx, transcription)

    assert event.author == "test_agent"
    assert event.invocation_id == "test-inv-1"
    assert event.input_transcription == nil
    assert event.output_transcription == transcription
  end

  test "handle_multiple_transcriptions", %{ctx: ctx} do
    events = []

    # 3 inputs
    events =
      Enum.reduce(0..2, events, fn i, acc ->
        t = %{text: "User message #{i}"}
        e = TranscriptionManager.handle_input_transcription(ctx, t)
        [e | acc]
      end)

    # 2 outputs
    events =
      Enum.reduce(0..1, events, fn i, acc ->
        t = %{text: "Model response #{i}"}
        e = TranscriptionManager.handle_output_transcription(ctx, t)
        [e | acc]
      end)

    events = Enum.reverse(events)
    assert length(events) == 5
    # No assert_not_called because we just return events here
  end

  test "get_transcription_stats_empty_session" do
    stats = TranscriptionManager.get_transcription_stats([])

    assert stats == %{
             "input_transcriptions" => 0,
             "output_transcriptions" => 0,
             "total_transcriptions" => 0
           }
  end

  test "get_transcription_stats_with_events" do
    events = [
      %Event{input_transcription: %{text: "User 1"}},
      %Event{output_transcription: %{text: "Model response"}},
      %Event{input_transcription: %{text: "User 2"}},
      %Event{}
    ]

    stats = TranscriptionManager.get_transcription_stats(events)

    assert stats == %{
             "input_transcriptions" => 2,
             "output_transcriptions" => 1,
             "total_transcriptions" => 3
           }
  end

  test "get_transcription_stats_missing_attributes" do
    events = [
      %Event{input_transcription: nil, output_transcription: nil},
      %Event{input_transcription: nil, output_transcription: nil}
    ]

    stats = TranscriptionManager.get_transcription_stats(events)

    assert stats == %{
             "input_transcriptions" => 0,
             "output_transcriptions" => 0,
             "total_transcriptions" => 0
           }
  end

  test "transcription_event_fields", %{ctx: ctx} do
    transcription = %{text: "Test transcription content", finished: true}

    event = TranscriptionManager.handle_input_transcription(ctx, transcription)
    assert event.input_transcription == transcription
  end

  test "transcription_with_different_data_types", %{ctx: ctx} do
    transcription = %{text: "Advanced transcription", finished: true}
    event = TranscriptionManager.handle_input_transcription(ctx, transcription)
    assert event.input_transcription == transcription
  end
end
