defmodule ADK.Memory.Entry do
  @moduledoc """
  A single memory entry.

  Mirrors Python ADK's `MemoryEntry` — stores content with optional metadata.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          author: String.t() | nil,
          metadata: map(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:id, :content]
  defstruct [
    :id,
    :content,
    :author,
    metadata: %{},
    timestamp: nil
  ]

  @doc """
  Create a new memory entry with an auto-generated ID and timestamp.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [id: generate_id(), timestamp: DateTime.utc_now()],
        opts
      )
    )
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
