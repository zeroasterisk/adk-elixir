defmodule ADK.Event do
  @moduledoc "The universal event struct — everything in ADK is an event."

  @type t :: %__MODULE__{
          id: String.t(),
          invocation_id: String.t() | nil,
          author: String.t(),
          branch: String.t() | nil,
          timestamp: DateTime.t(),
          content: map() | nil,
          partial: boolean(),
          actions: ADK.EventActions.t(),
          function_calls: [map()] | nil,
          function_responses: [map()] | nil,
          error: String.t() | nil
        }

  defstruct [
    :id,
    :invocation_id,
    :author,
    :branch,
    :timestamp,
    :content,
    :error,
    function_calls: nil,
    function_responses: nil,
    partial: false,
    actions: %ADK.EventActions{}
  ]

  @doc """
  Create a new event with auto-generated id and timestamp.

  ## Examples

      iex> event = ADK.Event.new(%{author: "user", content: %{parts: [%{text: "hi"}]}})
      iex> event.author
      "user"
      iex> is_binary(event.id)
      true
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    defaults = %{
      id: generate_id(),
      timestamp: DateTime.utc_now(),
      actions: %ADK.EventActions{}
    }

    struct!(__MODULE__, Map.merge(defaults, attrs))
  end

  @doc """
  Extract text content from an event.

  ## Examples

      iex> event = %ADK.Event{content: %{parts: [%{text: "Hello"}]}}
      iex> ADK.Event.text(event)
      "Hello"

      iex> ADK.Event.text(%ADK.Event{content: nil})
      nil
  """
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{content: %{parts: parts}}) when is_list(parts) do
    Enum.find_value(parts, fn
      %{text: t} -> t
      _ -> nil
    end)
  end

  def text(_), do: nil

  @doc """
  Check if event has text content.
  """
  @spec text?(t()) :: boolean()
  def text?(event), do: text(event) != nil

  @doc """
  Check if an event is a final response.

  ## Examples

      iex> e = %ADK.Event{partial: false, content: %{parts: [%{text: "Done"}]}, actions: %ADK.EventActions{}}
      iex> ADK.Event.final_response?(e)
      true

      iex> ADK.Event.final_response?(%ADK.Event{partial: true, content: %{parts: [%{text: "..."}]}, actions: %ADK.EventActions{}})
      false
  """
  @spec final_response?(t()) :: boolean()
  def final_response?(%__MODULE__{partial: false, content: c, actions: a})
      when not is_nil(c) do
    is_nil(a.transfer_to_agent) and (is_nil(c[:parts]) or not has_function_calls?(c))
  end

  def final_response?(_), do: false

  @doc "Create an error event."
  @spec error(term(), map()) :: t()
  def error(reason, attrs \\ %{}) do
    new(
      Map.merge(attrs, %{
        author: attrs[:author] || "system",
        error: inspect(reason),
        content: %{parts: [%{text: "Error: #{inspect(reason)}"}]}
      })
    )
  end

  defp has_function_calls?(%{parts: parts}) when is_list(parts) do
    Enum.any?(parts, fn
      %{function_call: _} -> true
      _ -> false
    end)
  end

  defp has_function_calls?(_), do: false

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
