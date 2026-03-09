defmodule Claw.Callbacks do
  @moduledoc """
  Logging callback that logs all LLM calls.

  Demonstrates the ADK callback system by logging before/after model calls.
  """

  @behaviour ADK.Callback

  require Logger

  @impl true
  def before_model(%{request: request} = ctx) do
    Logger.info("[Claw] LLM call → model=#{request[:model]} messages=#{length(request[:messages] || [])}")
    {:cont, ctx}
  end

  @impl true
  def after_model({:ok, response} = result, _ctx) do
    text = extract_text(response)
    preview = if text, do: String.slice(text, 0, 80), else: "(no text)"
    Logger.info("[Claw] LLM response ← #{preview}")
    result
  end

  def after_model({:error, reason} = result, _ctx) do
    Logger.warning("[Claw] LLM error ← #{inspect(reason)}")
    result
  end

  defp extract_text(%{content: %{parts: parts}}) when is_list(parts) do
    Enum.find_value(parts, fn
      %{text: t} -> t
      _ -> nil
    end)
  end

  defp extract_text(_), do: nil
end
