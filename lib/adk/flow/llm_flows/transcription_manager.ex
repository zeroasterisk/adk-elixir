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

defmodule ADK.Flows.LlmFlows.TranscriptionManager do
  @moduledoc """
  Manages transcription events for live streaming flows.
  """

  require Logger
  alias ADK.Event

  @doc """
  Handle user input transcription events.

  ## Arguments
  - `ctx`: The current invocation context (`ADK.Context.t()`).
  - `transcription`: The transcription data (usually a map with `:text` and optional `:finished`).
  """
  def handle_input_transcription(ctx, transcription) do
    create_and_save_transcription_event(ctx, transcription, "user", true)
  end

  @doc """
  Handle model output transcription events.

  ## Arguments
  - `ctx`: The current invocation context (`ADK.Context.t()`).
  - `transcription`: The transcription data.
  """
  def handle_output_transcription(ctx, transcription) do
    author =
      if ctx.agent do
        try do
          ADK.Agent.name(ctx.agent)
        rescue
          _ -> "model"
        end
      else
        "model"
      end

    create_and_save_transcription_event(ctx, transcription, author, false)
  end

  defp create_and_save_transcription_event(ctx, transcription, author, is_input) do
    type_str = if is_input, do: "input", else: "output"

    try do
      event_args = %{
        invocation_id: ctx.invocation_id,
        author: author,
        input_transcription: if(is_input, do: transcription, else: nil),
        output_transcription: if(not is_input, do: transcription, else: nil)
      }

      event = Event.new(event_args)

      # Save transcription event to session
      # (In python ADK this currently just logs and returns without actually appending)

      text =
        case transcription do
          %{text: t} -> t
          %{"text" => t} -> t
          _ -> "audio transcription"
        end

      Logger.debug("Saved #{type_str} transcription event for #{author}: #{text}")

      event
    rescue
      e ->
        Logger.error("Failed to save #{type_str} transcription event: #{inspect(e)}")
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Get statistics about transcription events in the session.

  Reads events from the context. In Elixir ADK, events are usually in the memory store,
  but for parity, we accept `events` directly (or a `session` map) as they are retrieved elsewhere.
  For exact parity, we'll take a list of events.
  """
  def get_transcription_stats(events) when is_list(events) do
    {input_count, output_count} =
      Enum.reduce(events, {0, 0}, fn event, {i, o} ->
        has_input = not is_nil(Map.get(event, :input_transcription))
        has_output = not is_nil(Map.get(event, :output_transcription))

        {if(has_input, do: i + 1, else: i), if(has_output, do: o + 1, else: o)}
      end)

    %{
      "input_transcriptions" => input_count,
      "output_transcriptions" => output_count,
      "total_transcriptions" => input_count + output_count
    }
  end
end
