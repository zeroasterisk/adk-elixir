defmodule ADK.Plugin.MultimodalToolResults do
  @moduledoc """
  A plugin that modifies function tool responses to support returning list of parts directly.

  Should be removed in favor of directly supporting FunctionResponsePart when these
  are supported outside of computer use tool.
  """
  @behaviour ADK.Plugin

  @parts_key :temp_parts_returned_by_tools

  @impl true
  def init(config), do: {:ok, config}

  @impl true
  def after_tool(_context, _tool_name, result) do
    case check_parts(result) do
      {:ok, parts} ->
        existing_parts = Process.get(@parts_key, [])
        Process.put(@parts_key, existing_parts ++ parts)
        nil

      :error ->
        result
    end
  end

  @impl true
  def before_model(_context, request) do
    saved_parts = Process.delete(@parts_key)

    if saved_parts && saved_parts != [] do
      messages = Map.get(request, :messages, [])

      new_messages =
        if messages == [] do
          [%{role: :user, parts: saved_parts}]
        else
          List.update_at(messages, -1, fn msg ->
            Map.update(msg, :parts, saved_parts, &(&1 ++ saved_parts))
          end)
        end

      {:ok, Map.put(request, :messages, new_messages)}
    else
      {:ok, request}
    end
  end

  # Check if a map is a valid Part
  defp is_part?(%{} = map) when map != %{} do
    valid_keys = [
      :text,
      :function_call,
      :function_response,
      :file_data,
      :executable_code,
      :code_execution_result,
      :inline_data
    ]

    Enum.any?(valid_keys, &Map.has_key?(map, &1))
  end
  defp is_part?(_), do: false

  defp check_parts(map) when is_map(map) and not is_struct(map) do
    if is_part?(map), do: {:ok, [map]}, else: :error
  end
  defp check_parts(list) when is_list(list) and list != [] do
    if Enum.all?(list, &is_part?/1), do: {:ok, list}, else: :error
  end
  defp check_parts(_), do: :error
end
