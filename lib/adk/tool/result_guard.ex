defmodule ADK.Tool.ResultGuard do
  @moduledoc """
  Truncates oversized tool results to protect the LLM context window.

  When a tool returns a result larger than the configured maximum, this module
  truncates it and appends a marker indicating the original size.

  ## Configuration

      config :adk, :max_tool_result_bytes, 50_000

  Default: 50,000 bytes.

  > **Beyond Python ADK:** This module has no equivalent in the Python ADK.
  > It was added to prevent tool results from consuming the entire context window.
  """

  @default_max_bytes 50_000

  @doc """
  Truncates `value` if its serialized form exceeds the configured maximum bytes.

  Returns the value unchanged if it fits within the limit.
  """
  @spec maybe_truncate(term()) :: term()
  def maybe_truncate(value) do
    max = max_bytes()
    {serialized, original?} = serialize(value)
    size = byte_size(serialized)

    if size <= max do
      value
    else
      keep = trunc(max * 0.8)
      truncated = binary_part(serialized, 0, keep)

      if original? do
        truncated <> "\n\n[TRUNCATED: result was #{size} bytes, showing first #{keep} bytes]"
      else
        truncated <> "\n\n[TRUNCATED: result was #{size} bytes (serialized), showing first #{keep} bytes]"
      end
    end
  end

  @doc """
  Returns the configured maximum tool result size in bytes.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes do
    Application.get_env(:adk, :max_tool_result_bytes, @default_max_bytes)
  end

  # Returns {serialized_string, is_original_string?}
  defp serialize(value) when is_binary(value), do: {value, true}

  defp serialize(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> {json, false}
      {:error, _} -> {inspect(value, limit: :infinity, printable_limit: :infinity), false}
    end
  end

  defp serialize(value), do: {inspect(value, limit: :infinity, printable_limit: :infinity), false}
end
