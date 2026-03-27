defmodule ADK.Tool.ResultGuard do
  @moduledoc """
  Truncates oversized tool results to protect the LLM context window.

  When a tool returns a result larger than the configured maximum, this module
  truncates it and appends a marker indicating the original size.

  ## Options

  All functions accept an optional `max_bytes` parameter:

      ResultGuard.maybe_truncate(value, max_bytes: 10_000)

  When not provided, falls back to application config:

      config :adk, :max_tool_result_bytes, 50_000

  Default: 50,000 bytes.

  > **Beyond Python ADK:** This module has no equivalent in the Python ADK.
  > It was added to prevent tool results from consuming the entire context window.
  """

  @default_max_bytes 50_000

  @type opts :: [max_bytes: pos_integer()]

  @doc """
  Truncates `value` if its serialized form exceeds the maximum bytes.

  ## Options

    * `:max_bytes` — override the maximum size (default: application config or #{@default_max_bytes})

  Returns the value unchanged if it fits within the limit.
  """
  @spec maybe_truncate(term(), opts()) :: term()
  def maybe_truncate(value, opts \\ []) do
    max = Keyword.get(opts, :max_bytes) || max_bytes()
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

  Reads from `Application.get_env(:adk, :max_tool_result_bytes)`, defaulting to #{@default_max_bytes}.
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
