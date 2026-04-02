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
  appending synthetic `function_response` parts for every orphaned
  `function_call`. Returns the messages unchanged when no repairs are needed.
  """
  @spec repair(list(map())) :: list(map())
  def repair([]), do: []

  def repair(messages) do
    messages = merge_consecutive_roles(messages)
    orphans = orphaned_calls(messages)

    case orphans do
      [] ->
        messages

      _ ->
        synthetic_parts =
          Enum.map(orphans, fn call ->
            fc = call.function_call

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

        messages ++ [%{role: :user, parts: synthetic_parts}]
    end
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
