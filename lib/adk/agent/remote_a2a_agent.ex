defmodule ADK.Agent.RemoteA2aAgent do
  @moduledoc """
  Agent that communicates with a remote A2A agent via A2A client.

  This agent wraps a remote A2A endpoint and forwards local events
  to it. It maintains a session with the remote agent using the
  `contextId` field.
  """

  @enforce_keys [:name, :target]
  defstruct [
    :name,
    :target,
    description: "",
    client_opts: [],
    full_history_when_stateless: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          target: String.t() | A2A.AgentCard.t(),
          description: String.t(),
          client_opts: keyword(),
          full_history_when_stateless: boolean()
        }

  @doc "Create a new RemoteA2aAgent."
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end

defimpl ADK.Agent, for: ADK.Agent.RemoteA2aAgent do
  require Logger

  def name(agent), do: agent.name
  def description(agent), do: agent.description
  def sub_agents(_agent), do: []

  def run(agent, ctx) do
    base_url = extract_url(agent.target)

    # 1. Figure out context ID
    context_id = get_context_id(agent, ctx)

    # 2. Extract un-sent messages
    {events_to_send, _has_previous_context?} = events_for_remote(agent, ctx, context_id)

    if events_to_send == [] do
      Logger.warning("No parts to send to remote A2A agent. Emitting empty event.")
      [
        ADK.Event.new(%{
          author: agent.name,
          content: nil,
          invocation_id: ctx.invocation_id,
          branch: ctx.branch
        })
      ]
    else
      message_parts = build_message_parts(events_to_send, agent.name)

      message_payload = %{
        "role" => "ROLE_USER",
        "parts" => message_parts
      }

      opts =
        if context_id do
          Keyword.put(agent.client_opts, :context_id, context_id)
        else
          agent.client_opts
        end

      case A2A.Client.send_message(base_url, message_payload, opts) do
        {:ok, result} ->
          handle_response(agent, ctx, result)

        {:error, reason} ->
          [
            ADK.Event.error(reason, %{
              author: agent.name,
              invocation_id: ctx.invocation_id,
              branch: ctx.branch
            })
          ]
      end
    end
  end

  # --- Helpers ---

  defp extract_url(%A2A.AgentCard{} = card), do: A2A.AgentCard.url(card) || raise "No URL found in AgentCard"
  defp extract_url(url) when is_binary(url), do: url

  defp get_context_id(agent, ctx) do
    if ctx.session_pid do
      ADK.Session.get_state(ctx.session_pid, "a2a_context_id_#{agent.name}")
    else
      # stateless mode, but we can check if it's stored in ctx.temp_state
      Map.get(ctx.temp_state, "a2a_context_id_#{agent.name}")
    end
  end

  defp events_for_remote(agent, ctx, context_id) do
    # Go backwards to find the last time this remote agent responded
    events =
      if ctx.session_pid do
        ADK.Session.get_events(ctx.session_pid)
      else
        []
      end

    events =
      if ctx.user_content do
        events ++ [ADK.Event.new(%{author: "user", content: ctx.user_content, invocation_id: ctx.invocation_id, branch: ctx.branch})]
      else
        events
      end

    events = Enum.reverse(events)

    {to_send, _rest} =
      Enum.split_while(events, fn event ->
        event.author != agent.name
      end)

    has_previous_context? = not is_nil(context_id)

    # If stateless and we don't have context, and full_history_when_stateless is true,
    # then send ALL events (don't break at author)
    to_send =
      if not agent.full_history_when_stateless and not has_previous_context? do
        to_send
      else
        if agent.full_history_when_stateless and not has_previous_context? do
          events
        else
          to_send
        end
      end

    {Enum.reverse(to_send), has_previous_context?}
  end

  defp build_message_parts(events, _agent_name) do
    Enum.flat_map(events, fn event ->
      cond do
        event.content == nil ->
          []
        parts = event.content["parts"] || event.content[:parts] ->
          # Map ADK content parts to A2A Parts format
          Enum.map(parts, fn
            %{text: t} -> %{"text" => t, "mediaType" => "text/plain"}
            %{"text" => t} -> %{"text" => t, "mediaType" => "text/plain"}
            other -> %{"text" => inspect(other), "mediaType" => "text/plain"}
          end)
        true ->
          []
      end
    end)
  end

  defp handle_response(agent, ctx, result) do
    # A2A v1 SendMessage returns a SendMessageResponse JSON object.
    # It contains "message" (A2A Message object)
    msg = result["message"] || result

    parts = Map.get(msg, "parts", [])
    text_content =
      Enum.map(parts, fn
        %{"text" => t} -> t
        %{"data" => _d, "mediaType" => _mt} -> "<media data attached>"
        _ -> ""
      end)
      |> Enum.join("\n")

    new_context_id = msg["contextId"]

    # If a new context ID was returned, record it as a state delta
    state_delta =
      if new_context_id do
        %{"a2a_context_id_#{agent.name}" => new_context_id}
      else
        %{}
      end

    content = %{
      parts: [%{text: text_content}]
    }

    [
      ADK.Event.new(%{
        author: agent.name,
        content: content,
        invocation_id: ctx.invocation_id,
        branch: ctx.branch,
        actions: %ADK.EventActions{state_delta: state_delta}
      })
    ]
  end
end
