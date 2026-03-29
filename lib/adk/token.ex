defmodule ADK.Token do
  @moduledoc """
  Standalone token estimation utility.

  Provides a simple character-based heuristic for estimating token counts,
  matching the Python ADK's approach of `len(text) // 4`.

  Accepts strings, message maps (with `:parts` containing `:text` fields),
  or lists of messages.

  **Beyond Python ADK** — provides a standalone token counting utility that
  can be used independently of the context compressor pipeline.

  ## Examples

      iex> ADK.Token.estimate_count("hello world")
      2

      iex> ADK.Token.estimate_count(%{role: :user, parts: [%{text: "hello world"}]})
      2

      iex> ADK.Token.estimate_count([
      ...>   %{role: :user, parts: [%{text: "hello"}]},
      ...>   %{role: :model, parts: [%{text: "hi there"}]}
      ...> ])
      3
  """

  @default_chars_per_token 4

  @doc """
  Estimate the token count for a string, message map, or list of messages.

  ## Options

    * `:chars_per_token` - Characters per token (default: 4)

  ## Examples

      iex> ADK.Token.estimate_count("hello world")
      2

      iex> ADK.Token.estimate_count("hello", chars_per_token: 2)
      2
  """
  @spec estimate_count(String.t() | map() | [map()], keyword()) :: non_neg_integer()
  def estimate_count(input, opts \\ [])

  def estimate_count(text, opts) when is_binary(text) do
    cpt = Keyword.get(opts, :chars_per_token, @default_chars_per_token)
    div(byte_size(text), max(cpt, 1))
  end

  def estimate_count(messages, opts) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + estimate_count(msg, opts)
    end)
  end

  def estimate_count(%{parts: parts}, opts) when is_list(parts) do
    cpt = Keyword.get(opts, :chars_per_token, @default_chars_per_token)

    total_chars =
      Enum.reduce(parts, 0, fn
        %{text: text}, acc when is_binary(text) -> acc + byte_size(text)
        _, acc -> acc
      end)

    div(total_chars, max(cpt, 1))
  end

  def estimate_count(%{}, _opts), do: 0
end
