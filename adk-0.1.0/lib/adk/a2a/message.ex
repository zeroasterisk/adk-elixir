defmodule ADK.A2A.Message do
  @moduledoc """
  Converts between ADK Events and A2A protocol messages.

  Bridges ADK's event system to the `A2A.Message` type from the
  [a2a](https://github.com/zeroasterisk/a2a-elixir) package.
  """

  @doc "Convert an ADK Event to an A2A message map."
  @spec from_event(ADK.Event.t()) :: map()
  def from_event(%ADK.Event{} = event) do
    role = if event.author == "user", do: "user", else: "agent"
    parts = event_to_parts(event)
    %{"role" => role, "parts" => parts}
  end

  @doc "Convert an A2A message map to an ADK Event."
  @spec to_event(map()) :: ADK.Event.t()
  def to_event(%{"role" => role, "parts" => parts}) do
    author = if role == "user", do: "user", else: "agent"
    content_parts = Enum.map(parts, &part_to_content/1)

    ADK.Event.new(%{
      author: author,
      content: %{parts: content_parts}
    })
  end

  def to_event(%{} = msg) do
    msg
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> to_event()
  end

  @doc "Convert an ADK Event to an `A2A.Message` struct."
  @spec to_a2a_message(ADK.Event.t()) :: A2A.Message.t()
  def to_a2a_message(%ADK.Event{} = event) do
    map = from_event(event)
    A2A.Message.from_map(map)
  end

  defp event_to_parts(%ADK.Event{content: %{parts: parts}}) when is_list(parts) do
    Enum.map(parts, &content_to_part/1)
  end

  defp event_to_parts(%ADK.Event{error: err}) when not is_nil(err) do
    [%{"type" => "text", "text" => "Error: #{err}"}]
  end

  defp event_to_parts(_), do: []

  defp content_to_part(%{text: text}), do: %{"type" => "text", "text" => text}
  defp content_to_part(%{"text" => text}), do: %{"type" => "text", "text" => text}

  defp content_to_part(%{function_call: fc}),
    do: %{"type" => "data", "data" => %{"function_call" => fc}}

  defp content_to_part(%{"function_call" => fc}),
    do: %{"type" => "data", "data" => %{"function_call" => fc}}

  defp content_to_part(other), do: %{"type" => "data", "data" => other}

  defp part_to_content(%{"type" => "text", "text" => text}), do: %{text: text}
  defp part_to_content(%{"type" => "file", "file" => file}), do: %{file: file}
  defp part_to_content(%{"type" => "data", "data" => data}), do: %{data: data}
  defp part_to_content(other), do: %{data: other}
end
