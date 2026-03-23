defmodule ADK.EventCompaction do
  @moduledoc """
  The compaction of the events.
  """

  @type t :: %__MODULE__{
          start_timestamp: float(),
          end_timestamp: float(),
          compacted_content: map()
        }

  @derive Jason.Encoder
  defstruct start_timestamp: 0.0,
            end_timestamp: 0.0,
            compacted_content: %{}

  @doc """
  Constructs an EventCompaction from a map (string or atom keys).

  Returns `nil` for `nil` input, passes through existing structs.
  """
  @spec from_map(map() | t() | nil) :: t() | nil
  def from_map(nil), do: nil
  def from_map(%__MODULE__{} = compaction), do: compaction

  def from_map(map) when is_map(map) do
    %__MODULE__{
      start_timestamp: Map.get(map, "start_timestamp") || Map.get(map, :start_timestamp) || 0.0,
      end_timestamp: Map.get(map, "end_timestamp") || Map.get(map, :end_timestamp) || 0.0,
      compacted_content:
        Map.get(map, "compacted_content") || Map.get(map, :compacted_content) || %{}
    }
  end
end
