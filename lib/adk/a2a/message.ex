if Code.ensure_loaded?(A2A.AgentCard) do
defmodule ADK.A2A.Message do
  @moduledoc """
  Converts between ADK Events and A2A protocol messages.

  Bridges ADK's event system to the `A2A.Message` type from the
  [a2a](https://github.com/zeroasterisk/a2a-elixir) package.
  """

  @doc "Convert an ADK Event to an A2A message map (wire format)."
  @spec from_event(ADK.Event.t()) :: map()
  def from_event(%ADK.Event{} = event) do
    msg = to_a2a_message(event)
    A2A.JSON.encode(msg)
  end

  @doc "Convert an A2A message (struct or map) to an ADK Event."
  @spec to_event(A2A.Message.t() | map()) :: ADK.Event.t()
  def to_event(%A2A.Message{} = msg) do
    author = if msg.role == :user, do: "user", else: "agent"
    content_parts = Enum.map(msg.parts, &part_to_content/1)

    ADK.Event.new(%{
      author: author,
      content: %{parts: content_parts}
    })
  end

  def to_event(%{} = map) do
    case A2A.JSON.decode(map, :message) do
      {:ok, msg} -> to_event(msg)
      {:error, _} ->
        # Fallback: handle simple maps with string role keys
        role = map["role"] || map[:role]
        author = case role do
          r when r in ["ROLE_USER", "user", :user] -> "user"
          _ -> "agent"
        end

        parts = map["parts"] || map[:parts] || []
        content_parts = Enum.map(parts, fn
          %{"text" => text} -> %{text: text}
          %{text: text} -> %{text: text}
          other -> %{data: other}
        end)

        ADK.Event.new(%{
          author: author,
          content: %{parts: content_parts}
        })
    end
  end

  @doc "Convert an ADK Event to an `A2A.Message` struct."
  @spec to_a2a_message(ADK.Event.t()) :: A2A.Message.t()
  def to_a2a_message(%ADK.Event{} = event) do
    parts = event_to_a2a_parts(event)

    if event.author == "user" do
      A2A.Message.new_user(parts)
    else
      A2A.Message.new_agent(parts)
    end
  end

  defp event_to_a2a_parts(%ADK.Event{content: %{parts: parts}}) when is_list(parts) do
    Enum.map(parts, fn
      %{text: text} -> A2A.Part.Text.new(text)
      %{"text" => text} -> A2A.Part.Text.new(text)
      %{data: data} -> A2A.Part.Data.new(data)
      %{"data" => data} -> A2A.Part.Data.new(data)
      other when is_map(other) -> A2A.Part.Data.new(other)
      other -> A2A.Part.Text.new(inspect(other))
    end)
  end

  defp event_to_a2a_parts(%ADK.Event{error: err}) when not is_nil(err) do
    [A2A.Part.Text.new("Error: #{err}")]
  end

  defp event_to_a2a_parts(_), do: []

  defp part_to_content(%A2A.Part.Text{text: t}), do: %{text: t}
  defp part_to_content(%A2A.Part.File{file: f}), do: %{file: f}
  defp part_to_content(%A2A.Part.Data{data: d}), do: %{data: d}
  defp part_to_content(other), do: %{data: other}
end
else
  defmodule ADK.A2A.Message do
    @moduledoc "Requires {:a2a, \"~> 0.2\"} optional dependency. Install it to enable A2A protocol support."
  end
end
