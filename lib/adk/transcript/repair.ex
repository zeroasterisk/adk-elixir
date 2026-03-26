defmodule ADK.Transcript.Repair do
  @moduledoc """
  Repairs conversation transcripts that contain orphaned tool calls.

  When an agent session crashes or is interrupted mid-tool-execution, the
  conversation history can contain `function_call` parts (in model messages)
  with no corresponding `function_response` (in user messages). LLMs —
  especially Gemini — reject such histories because every `function_call`
  **must** have a matching `function_response`.

  This module scans a message list, detects orphaned calls, and synthesises
  minimal error responses so the transcript is always well-formed.

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
  Repairs `messages` by appending synthetic `function_response` parts for
  every orphaned `function_call`. Returns the messages unchanged when there
  are no orphans.
  """
  @spec repair(list(map())) :: list(map())
  def repair([]), do: []

  def repair(messages) do
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
