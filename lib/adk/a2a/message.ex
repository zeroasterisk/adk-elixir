if Code.ensure_loaded?(A2A.AgentCard) and function_exported?(A2A.AgentCard, :new, 1) do
defmodule ADK.A2A.Message do
  @moduledoc """
  Converts between ADK Events and A2A protocol messages.

  Bridges ADK's event system to the `A2A.Message` type from the
  [a2a](https://github.com/zeroasterisk/a2a-elixir) package.
  """

  @doc "Convert an ADK Event to an A2A message map (wire format)."
  @spec from_event(ADK.Event.t()) :: map()
  def from_event(%ADK.Event{} = event) do
    event
    |> to_a2a_message()
    |> A2A.Message.to_map()
  end

  @doc "Convert an A2A message (struct or map) to an ADK Event."
  @spec to_event(A2A.Message.t() | map()) :: ADK.Event.t()
  def to_event(%A2A.Message{} = msg) do
    author = if msg.role == "ROLE_USER", do: "user", else: "agent"
    content_parts = Enum.map(msg.parts, &part_to_content/1)

    ADK.Event.new(%{
      author: author,
      content: %{parts: content_parts}
    })
  end

  def to_event(%{} = map) do
    map
    |> A2A.Message.from_map()
    |> to_event()
  end

  @doc "Convert an ADK Event to an `A2A.Message` struct."
  @spec to_a2a_message(ADK.Event.t()) :: A2A.Message.t()
  def to_a2a_message(%ADK.Event{} = event) do
    role = if event.author == "user", do: "ROLE_USER", else: "ROLE_AGENT"
    parts = event_to_a2a_parts(event)

    A2A.Message.new(role, parts)
  end

  defp event_to_a2a_parts(%ADK.Event{content: %{parts: parts}}) when is_list(parts) do
    Enum.map(parts, fn
      %{text: text} -> A2A.Part.text(text)
      %{"text" => text} -> A2A.Part.text(text)
      %{file: file} -> A2A.Part.file_url(file)
      %{"file" => file} -> A2A.Part.file_url(file)
      %{data: data} -> A2A.Part.data(data)
      %{"data" => data} -> A2A.Part.data(data)
      other when is_map(other) -> A2A.Part.data(other)
      other -> A2A.Part.text(inspect(other))
    end)
  end

  defp event_to_a2a_parts(%ADK.Event{error: err}) when not is_nil(err) do
    [A2A.Part.text("Error: #{err}")]
  end

  defp event_to_a2a_parts(_), do: []

  defp part_to_content(%A2A.Part{text: t}) when not is_nil(t), do: %{text: t}
  defp part_to_content(%A2A.Part{url: u}) when not is_nil(u), do: %{file: u}
  defp part_to_content(%A2A.Part{data: d}) when not is_nil(d), do: %{data: d}
  defp part_to_content(other), do: %{data: other}
end
else
  defmodule ADK.A2A.Message do
    @moduledoc "Requires {:a2a, \"~> 0.2\"} optional dependency. Install it to enable A2A protocol support."
  end
end
