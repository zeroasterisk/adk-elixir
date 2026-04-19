defmodule ADK.Transcript.Repair do
  @moduledoc """
  Repairs conversation transcripts to satisfy Gemini API turn-ordering rules.

  The Gemini API requires strict alternating user/model turns and that every
  `function_call` has a matching `function_response`. This module provides
  two repair passes:

  1. **Consecutive-role merging** — folds adjacent messages with the same
     role into a single message by concatenating their `parts` lists.
  2. **Orphaned-call synthesis** — appends synthetic error responses for any
     `function_call` that lacks a corresponding `function_response`.

  `repair/1` runs both passes in order (merge first, then orphan repair).

  > **Elixir-only enhancement** — this repair pass does not exist in the
  > upstream Python ADK. It is specific to ADK Elixir.
  """

  @error_message "Tool call was interrupted and did not return a result."

  @doc """
  Returns the list of `function_call` maps that have no matching
  `function_response` in `messages`. Useful for debugging.
  """
  @spec orphaned_calls(list(map())) :: list(map())
  def orphaned_calls(messages) do
    calls = collect_calls(messages)
    responses = collect_responses(messages)

    Enum.reject(calls, fn call -> matched?(call, responses) end)
  end

  @doc """
  Merges consecutive messages that share the same role into a single message
  by concatenating their `parts` lists. The merged message keeps the role
  from the first message in each run.
  """
  @spec merge_consecutive_roles(list(map())) :: list(map())
  def merge_consecutive_roles([]), do: []

  def merge_consecutive_roles(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn msg, acc ->
        role = msg[:role] || msg["role"]

        case acc do
          nil ->
            {:cont, {role, msg}}

          {acc_role, acc_msg} when acc_role == role ->
            acc_parts = acc_msg[:parts] || acc_msg["parts"] || []
            msg_parts = msg[:parts] || msg["parts"] || []
            merged = Map.put(acc_msg, :parts, acc_parts ++ msg_parts)
            {:cont, {acc_role, merged}}

          {_acc_role, acc_msg} ->
            {:cont, acc_msg, {role, msg}}
        end
      end,
      fn
        nil -> {:cont, []}
        {_role, acc_msg} -> {:cont, acc_msg, nil}
      end
    )
  end

  @doc """
  Repairs `messages` by first merging consecutive same-role turns, then
  inserting synthetic `function_response` parts immediately after turns
  that contain orphaned `function_call`s. Returns the messages unchanged
  when no repairs are needed.

  When a model turn contains orphaned calls (function calls without matching
  responses), a synthetic user turn with error responses is inserted immediately
  after that model turn, rather than appending all synthetics at the end.
  This preserves the temporal ordering of tool calls and responses.
  """
  @spec repair(list(map())) :: list(map())
  def repair([]), do: []

  def repair(messages) do
    messages = merge_consecutive_roles(messages)
    all_responses = collect_responses(messages)

    # Process messages and insert synthetic responses immediately after
    # turns containing orphaned calls
    messages
    |> Enum.flat_map(fn msg ->
      parts = msg[:parts] || msg["parts"] || []

      # Find orphaned calls in this specific message
      calls_in_msg = Enum.filter(parts, &function_call?/1)
      orphans_in_msg = Enum.reject(calls_in_msg, fn call -> matched?(call, all_responses) end)

      case orphans_in_msg do
        [] ->
          # No orphans in this message, return as-is
          [msg]

        orphans ->
          # Create synthetic response for this message's orphaned calls
          synthetic_parts =
            Enum.map(orphans, fn call ->
              fc = call[:function_call] || call["function_call"]

              resp = %{
                name: fc[:name] || fc["name"],
                response: %{error: @error_message}
              }

              resp =
                cond do
                  fc[:id] -> Map.put(resp, :id, fc[:id])
                  fc["id"] -> Map.put(resp, :id, fc["id"])
                  true -> resp
                end

              %{function_response: resp}
            end)

          synthetic_msg = %{role: :user, parts: synthetic_parts}
          # Insert synthetic response immediately after this message
          [msg, synthetic_msg]
      end
    end)
  end

  # -- Private helpers -------------------------------------------------------

  defp collect_calls(messages) do
    Enum.flat_map(messages, fn msg ->
      (msg[:parts] || msg["parts"] || [])
      |> Enum.filter(&function_call?/1)
    end)
  end

  defp collect_responses(messages) do
    Enum.flat_map(messages, fn msg ->
      (msg[:parts] || msg["parts"] || [])
      |> Enum.filter(&function_response?/1)
    end)
  end

  defp function_call?(%{function_call: _}), do: true
  defp function_call?(%{"function_call" => _}), do: true
  defp function_call?(_), do: false

  defp function_response?(%{function_response: _}), do: true
  defp function_response?(%{"function_response" => _}), do: true
  defp function_response?(_), do: false

  # A call is matched if any response shares the same id, or — when ids are
  # absent — shares the same name (positional fallback).
  defp matched?(call, responses) do
    fc = call[:function_call] || call["function_call"]
    call_id = fc[:id] || fc["id"]
    call_name = fc[:name] || fc["name"]

    Enum.any?(responses, fn resp ->
      fr = resp[:function_response] || resp["function_response"]
      resp_id = fr[:id] || fr["id"]
      resp_name = fr[:name] || fr["name"]

      cond do
        # Both have ids — match by id
        call_id != nil and resp_id != nil -> call_id == resp_id
        # No ids — match by name
        call_id == nil and resp_id == nil -> call_name == resp_name
        # Mixed — no match
        true -> false
      end
    end)
  end
end
