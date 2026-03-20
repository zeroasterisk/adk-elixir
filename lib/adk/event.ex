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
            partial: nil,
            actions: nil

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

  def text(event) do
    parts(event)
    |> Enum.find_value(fn
      %{"text" => text} -> text
      %{text: text} -> text
      _ -> nil
    end)
  end

  def final_response?(event) do
    transfer = get_flex(event.actions, "transfer_to_agent")
    !event.partial && !transfer
  end

  def error(reason, opts) do
    error_str = if is_binary(reason), do: reason, else: inspect(reason)
    opts_map = if is_map(opts), do: opts, else: Map.new(opts)
    new(Map.put(opts_map, :error, error_str))
  end

  def to_map(event) do
    Map.from_struct(event)
  end

  def function_calls(event) do
    for part <- parts(event),
        call = get_flex(part, "function_call"),
        call != nil,
        do: call
  end

  def function_responses(event) do
    for part <- parts(event),
        response = get_flex(part, "function_response"),
        response != nil,
        do: response
  end

  @doc "Returns true if the event contains at least one function call."
  def has_function_calls?(event) do
    function_calls(event) != []
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
      val -> val
    end
  end
  defp get_flex(_map, _key), do: nil

  def on_branch?(event, branch) do
    case {event.branch, branch} do
      {nil, _} -> true
      {event_branch, target_branch} ->
        # An event is visible on a branch if either:
        # 1. The event's branch is a prefix of the target (parent events visible to children)
        # 2. The target branch is a prefix of the event's branch (same branch)
        String.starts_with?(target_branch, event_branch) or
          String.starts_with?(event_branch, target_branch)
    end
  end
end
