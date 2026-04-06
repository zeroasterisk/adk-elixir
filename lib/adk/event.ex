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

defmodule ADK.Event do
  @moduledoc """
  Represents an event in the ADK.
  """

  defstruct type: nil,
            data: nil,
            custom_metadata: %{},
            error: nil,
            content: nil,
            id: nil,
            invocation_id: nil,
            author: nil,
            branch: nil,
            timestamp: nil,
            partial: false,
            actions: %ADK.EventActions{},
            input_transcription: nil,
            output_transcription: nil

  @type t :: %__MODULE__{
          type: atom() | nil,
          data: any(),
          custom_metadata: map(),
          error: String.t() | nil,
          content: map() | nil,
          id: String.t() | nil,
          invocation_id: String.t() | nil,
          author: String.t() | nil,
          branch: String.t() | nil,
          timestamp: DateTime.t() | nil,
          partial: boolean() | nil,
          actions: ADK.EventActions.t() | nil,
          input_transcription: map() | nil,
          output_transcription: map() | nil
        }

  @doc "Create a new event with auto-generated ID and timestamp."
  @spec new(map() | keyword()) :: t()
  def new(opts) do
    opts_map = if is_map(opts), do: opts, else: Map.new(opts)

    defaults = %{
      id: generate_id(),
      timestamp: DateTime.utc_now()
    }

    struct(__MODULE__, Map.merge(defaults, opts_map))
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc "Extract text from the event's content parts, falling back to error."
  @spec text(t()) :: String.t() | nil
  def text(event) do
    text_part =
      parts(event)
      |> Enum.find_value(fn
        %{"text" => text} -> text
        %{text: text} -> text
        _ -> nil
      end)

    text_part || event.error
  end

  @doc "Returns true if this event is a final response (not partial, no transfer, no tool calls)."
  @spec final_response?(t()) :: boolean()
  def final_response?(event) do
    transfer = get_flex(event.actions, "transfer_to_agent")
    !event.partial && !transfer && !has_function_calls?(event)
  end

  @doc "Create an error event."
  @spec error(term(), map() | keyword()) :: t()
  def error(reason, opts) do
    error_str = if is_binary(reason), do: reason, else: inspect(reason)
    opts_map = if is_map(opts), do: opts, else: Map.new(opts)
    new(Map.put(opts_map, :error, error_str))
  end

  @doc "Convert an event to a plain map, serializing timestamps and actions."
  @spec to_map(t()) :: map()
  def to_map(event) do
    event
    |> Map.from_struct()
    |> Map.update(:timestamp, nil, fn
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      nil -> nil
      other -> other
    end)
    |> Map.update(:actions, nil, fn
      %ADK.EventActions{} = a -> Map.from_struct(a)
      nil -> %ADK.EventActions{} |> Map.from_struct()
      other -> other
    end)
  end

  @doc "Extract function call parts from the event's content."
  @spec function_calls(t()) :: [map()]
  def function_calls(event) do
    for part <- parts(event),
        call = get_flex(part, "function_call"),
        call != nil,
        do: call
  end

  @doc "Extract function response parts from the event's content."
  @spec function_responses(t()) :: [map()]
  def function_responses(event) do
    for part <- parts(event),
        response = get_flex(part, "function_response"),
        response != nil,
        do: response
  end

  @doc "Returns true if the event contains at least one function call."
  @spec has_function_calls?(t()) :: boolean()
  def has_function_calls?(event) do
    function_calls(event) != []
  end

  @doc "Returns true if the event contains at least one function response."
  @spec has_function_responses?(t()) :: boolean()
  def has_function_responses?(event) do
    function_responses(event) != []
  end

  @doc "Returns true if the event has text content (not just tool calls)."
  @spec text?(t()) :: boolean()
  def text?(event), do: text(event) != nil

  @doc "Returns true if this is a compaction event."
  @spec compaction?(t()) :: boolean()
  def compaction?(event), do: event.author == "system:compaction"

  @doc "Reconstruct an event from a map (string or atom keys)."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    fields = [
      :type,
      :data,
      :custom_metadata,
      :error,
      :content,
      :id,
      :invocation_id,
      :author,
      :branch,
      :timestamp,
      :partial,
      :actions,
      :input_transcription,
      :output_transcription
    ]

    attrs =
      Enum.reduce(fields, %{}, fn field, acc ->
        key_str = Atom.to_string(field)
        val = Map.get(map, field) || Map.get(map, key_str)
        if val != nil, do: Map.put(acc, field, val), else: acc
      end)

    # Coerce timestamp from ISO 8601 string to DateTime
    attrs =
      case attrs[:timestamp] do
        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> Map.put(attrs, :timestamp, dt)
            _ -> attrs
          end

        _ ->
          attrs
      end

    # Coerce actions from map to EventActions struct
    attrs =
      case attrs[:actions] do
        m when is_map(m) and not is_struct(m) ->
          compaction =
            case Map.get(m, "compaction") || Map.get(m, :compaction) do
              nil -> nil
              comp_map -> ADK.EventCompaction.from_map(comp_map)
            end

          ea =
            struct(ADK.EventActions, %{
              state_delta: Map.get(m, "state_delta") || Map.get(m, :state_delta) || %{},
              artifact_delta: Map.get(m, "artifact_delta") || Map.get(m, :artifact_delta) || %{},
              requested_auth_configs:
                Map.get(m, "requested_auth_configs") || Map.get(m, :requested_auth_configs) || %{},
              transfer_to_agent:
                Map.get(m, "transfer_to_agent") || Map.get(m, :transfer_to_agent),
              escalate: Map.get(m, "escalate") || Map.get(m, :escalate) || false,
              skip_summarization:
                Map.get(m, "skip_summarization") || Map.get(m, :skip_summarization) || false,
              end_of_agent: Map.get(m, "end_of_agent") || Map.get(m, :end_of_agent) || false,
              compaction: compaction
            })

          Map.put(attrs, :actions, ea)

        _ ->
          attrs
      end

    event = struct(__MODULE__, attrs)

    # Migrate legacy top-level function_calls/function_responses into content.parts
    event = migrate_legacy_function_calls(event, map)
    event = migrate_legacy_function_responses(event, map)
    event
  end

  defp migrate_legacy_function_calls(event, map) do
    legacy = Map.get(map, "function_calls") || Map.get(map, :function_calls)

    if is_list(legacy) and length(legacy) > 0 do
      new_parts = Enum.map(legacy, fn fc -> %{function_call: fc} end)

      existing_parts =
        case event.content do
          %{parts: p} when is_list(p) -> p
          %{"parts" => p} when is_list(p) -> p
          _ -> []
        end

      %{event | content: %{parts: existing_parts ++ new_parts}}
    else
      event
    end
  end

  defp migrate_legacy_function_responses(event, map) do
    legacy = Map.get(map, "function_responses") || Map.get(map, :function_responses)

    if is_list(legacy) and length(legacy) > 0 do
      new_parts = Enum.map(legacy, fn fr -> %{function_response: fr} end)

      existing_parts =
        case event.content do
          %{parts: p} when is_list(p) -> p
          %{"parts" => p} when is_list(p) -> p
          _ -> []
        end

      %{event | content: %{parts: existing_parts ++ new_parts}}
    else
      event
    end
  end

  @doc false
  # Get parts from event content, handling both string and atom keys
  defp parts(event) do
    case event.content do
      nil -> []
      content -> get_flex(content, "parts") || []
    end
  end

  @doc false
  # Access a map key flexibly: try string key first, then atom key.
  # Handles maps with either string or atom keys (e.g., from JSON decode vs internal construction).
  defp get_flex(nil, _key), do: nil

  defp get_flex(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end

      val ->
        val
    end
  end

  defp get_flex(_map, _key), do: nil

  @doc "Check if an event is visible on a given branch."
  @spec on_branch?(t(), String.t() | nil) :: boolean()
  def on_branch?(event, branch) do
    case {event.branch, branch} do
      {nil, _} ->
        true

      {_, nil} ->
        true

      {event_branch, target_branch} when event_branch == target_branch ->
        true

      {event_branch, target_branch} ->
        # An event is visible on a branch only if the event's branch is a
        # proper ancestor of the target branch (parent events visible to children).
        # We require a dot separator to avoid partial-name matches (e.g. "rooter" vs "root").
        String.starts_with?(target_branch, event_branch <> ".")
    end
  end
end
