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
  Extract function calls from event content parts.

  In the ADK event model, function calls are embedded in `content.parts`
  as `%{function_call: %{name: ..., args: ...}}` — not as top-level fields.

  ## Examples

      iex> event = %ADK.Event{content: %{parts: [%{function_call: %{name: "search", args: %{}}}]}}
      iex> ADK.Event.function_calls(event)
      [%{name: "search", args: %{}}]

      iex> ADK.Event.function_calls(%ADK.Event{content: %{parts: [%{text: "hi"}]}})
      []
  """
  @spec function_calls(t()) :: [map()]
  def function_calls(%__MODULE__{content: %{parts: parts}}) when is_list(parts) do
    Enum.flat_map(parts, fn
      %{function_call: fc} -> [fc]
      _ -> []
    end)
  end

  def function_calls(_), do: []

  @doc """
  Extract function responses from event content parts.

  ## Examples

      iex> event = %ADK.Event{content: %{parts: [%{function_response: %{name: "search", response: %{result: "ok"}}}]}}
      iex> ADK.Event.function_responses(event)
      [%{name: "search", response: %{result: "ok"}}]
  """
  @spec function_responses(t()) :: [map()]
  def function_responses(%__MODULE__{content: %{parts: parts}}) when is_list(parts) do
    Enum.flat_map(parts, fn
      %{function_response: fr} -> [fr]
      _ -> []
    end)
  end

  def function_responses(_), do: []

  @doc """
  Check if event has function calls in its content parts.
  """
  @spec has_function_calls?(t()) :: boolean()
  def has_function_calls?(%__MODULE__{} = event), do: function_calls(event) != []

  @doc """
  Check if event has function responses in its content parts.
  """
  @spec has_function_responses?(t()) :: boolean()
  def has_function_responses?(%__MODULE__{} = event), do: function_responses(event) != []

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
  def final_response?(%__MODULE__{partial: false, content: c, actions: a} = event)
      when not is_nil(c) do
    is_nil(a.transfer_to_agent) and not has_function_calls?(event)
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

  @doc """
  Convert an Event struct to a plain map suitable for JSON serialization.

  ## Examples

      iex> event = ADK.Event.new(%{author: "agent", content: %{parts: [%{text: "hi"}]}})
      iex> map = ADK.Event.to_map(event)
      iex> map.author
      "agent"
      iex> is_binary(map.timestamp)
      true
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      id: event.id,
      invocation_id: event.invocation_id,
      author: event.author,
      branch: event.branch,
      timestamp: event.timestamp && DateTime.to_iso8601(event.timestamp),
      content: event.content,
      partial: event.partial,
      error: event.error,
      actions: %{
        state_delta: event.actions.state_delta,
        transfer_to_agent: event.actions.transfer_to_agent,
        escalate: event.actions.escalate,
        skip_summarization: event.actions.skip_summarization
      }
    }
  end

  @doc """
  Convert a plain map (e.g., from JSON) back to an Event struct.

  ## Examples

      iex> event = ADK.Event.new(%{author: "user", content: %{parts: [%{text: "hello"}]}})
      iex> roundtripped = event |> ADK.Event.to_map() |> ADK.Event.from_map()
      iex> roundtripped.author
      "user"
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    map = for {k, v} <- map, into: %{}, do: {to_string(k), v}

    actions =
      case map["actions"] do
        nil ->
          %ADK.EventActions{}

        a ->
          a = for {k, v} <- a, into: %{}, do: {to_string(k), v}

          %ADK.EventActions{
            state_delta: a["state_delta"] || %{},
            transfer_to_agent: a["transfer_to_agent"],
            escalate: a["escalate"] || false,
            skip_summarization: a["skip_summarization"] || false
          }
      end

    timestamp =
      case map["timestamp"] do
        nil -> nil
        %DateTime{} = dt -> dt
        ts when is_binary(ts) -> DateTime.from_iso8601(ts) |> elem(1)
      end

    # Migrate legacy top-level function_calls/function_responses into content.parts
    content = migrate_legacy_function_fields(map["content"], map["function_calls"], map["function_responses"])

    %__MODULE__{
      id: map["id"],
      invocation_id: map["invocation_id"],
      author: map["author"],
      branch: map["branch"],
      timestamp: timestamp,
      content: content,
      partial: map["partial"] || false,
      error: map["error"],
      actions: actions
    }
  end

  defp migrate_legacy_function_fields(content, nil, nil), do: content
  defp migrate_legacy_function_fields(content, calls, responses) do
    existing_parts = (content && content["parts"]) || (content && content[:parts]) || []

    call_parts =
      case calls do
        nil -> []
        list when is_list(list) -> Enum.map(list, fn fc -> %{function_call: fc} end)
      end

    response_parts =
      case responses do
        nil -> []
        list when is_list(list) -> Enum.map(list, fn fr -> %{function_response: fr} end)
      end

    extra = call_parts ++ response_parts
    if extra == [] do
      content
    else
      role = (content && (content["role"] || content[:role])) || :model
      %{role: role, parts: existing_parts ++ extra}
    end
  end

  @doc """
  Check if an event belongs to a given branch path.

  An event is "on branch" if its branch is a prefix of, or equal to, the
  current branch. This implements Python ADK's `_is_event_belongs_to_branch`
  logic — events from ancestors and the current agent are visible, but events
  from sibling branches are filtered out.

  Events with `nil` branch are considered universal (visible to all branches).

  ## Examples

      iex> ADK.Event.on_branch?(%ADK.Event{branch: nil}, "root.router")
      true

      iex> ADK.Event.on_branch?(%ADK.Event{branch: "root"}, "root.router.weather")
      true

      iex> ADK.Event.on_branch?(%ADK.Event{branch: "root.router"}, "root.router.weather")
      true

      iex> ADK.Event.on_branch?(%ADK.Event{branch: "root.router.news"}, "root.router.weather")
      false

      iex> ADK.Event.on_branch?(%ADK.Event{branch: "root.router.weather"}, "root.router.weather")
      true
  """
  @spec on_branch?(t(), String.t() | nil) :: boolean()
  def on_branch?(%__MODULE__{branch: nil}, _current_branch), do: true
  def on_branch?(%__MODULE__{}, nil), do: true

  def on_branch?(%__MODULE__{branch: event_branch}, current_branch)
      when is_binary(event_branch) and is_binary(current_branch) do
    event_branch == current_branch or
      String.starts_with?(current_branch, event_branch <> ".")
  end

  @doc """
  Check if an event is a compaction summary event.

  ## Examples

      iex> ADK.Event.compaction?(%ADK.Event{author: "system:compaction"})
      true

      iex> ADK.Event.compaction?(%ADK.Event{author: "user"})
      false
  """
  @spec compaction?(t()) :: boolean()
  def compaction?(%__MODULE__{author: "system:compaction"}), do: true
  def compaction?(_), do: false

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
