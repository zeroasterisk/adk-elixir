if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ADK.Phoenix.ChatLive do
    @moduledoc """
    A drop-in Phoenix LiveView chat interface for ADK agents.

    Renders a complete chat UI that sends user messages to an ADK agent
    via `ADK.Runner.run/5`, streams responses back in real-time, and
    maintains multi-turn session state.

    ## Usage

    In your router:

        live "/chat", ADK.Phoenix.ChatLive,
          session: %{
            "agent" => &MyApp.Agents.assistant/0,
            "app_name" => "my_app"
          }

    Or mount with a wrapper LiveView for more control:

        defmodule MyAppWeb.ChatLive do
          use MyAppWeb, :live_view

          def mount(_params, _session, socket) do
            agent = MyApp.Agents.assistant()

            {:ok,
             socket
             |> assign(:agent, agent)
             |> assign(:app_name, "my_app")
             |> ADK.Phoenix.ChatLive.init_chat()}
          end

          defdelegate handle_event(event, params, socket), to: ADK.Phoenix.ChatLive
          defdelegate handle_info(msg, socket), to: ADK.Phoenix.ChatLive
          defdelegate render(assigns), to: ADK.Phoenix.ChatLive
        end

    ## Direct mount

    For direct use, pass agent config through the session:

        live_session :chat, session: %{"agent_mod" => MyApp.Agents, "agent_fun" => :assistant} do
          live "/chat", ADK.Phoenix.ChatLive
        end
    """

    use Phoenix.LiveView

    @doc """
    Initialize chat assigns on a socket. Call from your own LiveView's mount/3.

    Expects `:agent` and `:app_name` to already be assigned.
    """
    @spec init_chat(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
    def init_chat(socket, opts \\ []) do
      user_id = Keyword.get(opts, :user_id, "anonymous")
      session_id = Keyword.get(opts, :session_id, generate_session_id())

      socket
      |> assign(:messages, [])
      |> assign(:loading, false)
      |> assign(:user_id, user_id)
      |> assign(:session_id, session_id)
      |> assign(:input_value, "")
    end

    @impl true
    def mount(_params, session, socket) do
      agent = resolve_agent(session)
      app_name = session["app_name"] || "adk_chat"

      socket =
        socket
        |> assign(:agent, agent)
        |> assign(:app_name, app_name)
        |> init_chat()

      {:ok, socket}
    end

    @impl true
    def handle_event("send_message", %{"message" => message}, socket)
        when message != "" do
      message = String.trim(message)

      if message == "" do
        {:noreply, socket}
      else
        user_msg = %{role: "user", text: message, id: generate_id()}

        runner = %ADK.Runner{
          app_name: socket.assigns.app_name,
          agent: socket.assigns.agent
        }

        {:ok, _pid} =
          ADK.Runner.Async.run(
            runner,
            socket.assigns.user_id,
            socket.assigns.session_id,
            message
          )

        socket =
          socket
          |> update(:messages, &(&1 ++ [user_msg]))
          |> assign(:loading, true)
          |> assign(:input_value, "")

        {:noreply, socket}
      end
    end

    def handle_event("send_message", _params, socket) do
      {:noreply, socket}
    end

    def handle_event("form_change", %{"message" => value}, socket) do
      {:noreply, assign(socket, :input_value, value)}
    end

    @impl true
    def handle_info({:adk_event, event}, socket) do
      text = extract_text(event)

      if text && text != "" do
        agent_msg = %{role: "agent", text: text, id: generate_id(), author: event.author}

        socket = update(socket, :messages, &(&1 ++ [agent_msg]))
        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end

    def handle_info({:adk_done, _events}, socket) do
      {:noreply, assign(socket, :loading, false)}
    end

    def handle_info({:adk_error, reason}, socket) do
      error_msg = %{role: "error", text: "Error: #{inspect(reason)}", id: generate_id()}

      socket =
        socket
        |> update(:messages, &(&1 ++ [error_msg]))
        |> assign(:loading, false)

      {:noreply, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id="adk-chat" class="adk-chat" style={default_container_style()}>
        <div id="adk-chat-messages" class="adk-chat-messages" phx-update="append" style={default_messages_style()}>
          <%= for msg <- @messages do %>
            <div id={msg.id} class={"adk-chat-message adk-chat-message--#{msg.role}"} style={message_style(msg.role)}>
              <div class="adk-chat-message__content" style={bubble_style(msg.role)}>
                <%= msg.text %>
              </div>
            </div>
          <% end %>
        </div>

        <%= if @loading do %>
          <div class="adk-chat-typing" style={typing_style()}>
            <span class="adk-chat-typing__dot" style={dot_style()}>●</span>
            <span class="adk-chat-typing__dot" style={dot_style()}>●</span>
            <span class="adk-chat-typing__dot" style={dot_style()}>●</span>
          </div>
        <% end %>

        <form phx-submit="send_message" phx-change="form_change" class="adk-chat-input" style={input_container_style()}>
          <input
            type="text"
            name="message"
            value={@input_value}
            placeholder="Type a message..."
            autocomplete="off"
            style={input_style()}
            phx-debounce="50"
          />
          <button type="submit" disabled={@loading} style={button_style()}>
            Send
          </button>
        </form>
      </div>
      """
    end

    # --- Private helpers ---

    defp resolve_agent(%{"agent" => agent}) when is_function(agent, 0), do: agent.()
    defp resolve_agent(%{"agent" => agent}), do: agent

    defp resolve_agent(%{"agent_mod" => mod, "agent_fun" => fun}) do
      apply(mod, fun, [])
    end

    defp resolve_agent(_session) do
      raise ArgumentError,
            "ADK.Phoenix.ChatLive requires an agent in the session. " <>
              "Pass %{\"agent\" => agent} or %{\"agent_mod\" => mod, \"agent_fun\" => fun}."
    end

    defp extract_text(%ADK.Event{content: %{parts: parts}}) when is_list(parts) do
      parts
      |> Enum.map_join("", fn
        %{text: text} -> text
        _ -> ""
      end)
    end

    defp extract_text(_), do: nil

    defp generate_id, do: "msg-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    defp generate_session_id, do: "chat-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    # Minimal inline styles so the component works without external CSS.
    # Users can override with their own CSS targeting the .adk-chat-* classes.

    defp default_container_style do
      "display:flex;flex-direction:column;height:100%;max-height:600px;border:1px solid #e0e0e0;border-radius:8px;overflow:hidden;font-family:system-ui,sans-serif;"
    end

    defp default_messages_style do
      "flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:8px;"
    end

    defp message_style("user"), do: "display:flex;justify-content:flex-end;"
    defp message_style(_), do: "display:flex;justify-content:flex-start;"

    defp bubble_style("user") do
      "background:#0084ff;color:white;padding:8px 14px;border-radius:18px 18px 4px 18px;max-width:75%;word-wrap:break-word;"
    end

    defp bubble_style("error") do
      "background:#fee;color:#c00;padding:8px 14px;border-radius:18px 18px 18px 4px;max-width:75%;word-wrap:break-word;"
    end

    defp bubble_style(_) do
      "background:#f0f0f0;color:#333;padding:8px 14px;border-radius:18px 18px 18px 4px;max-width:75%;word-wrap:break-word;"
    end

    defp typing_style, do: "padding:8px 16px;color:#999;display:flex;gap:4px;align-items:center;"
    defp dot_style, do: "animation:adk-blink 1.4s infinite;font-size:10px;"

    defp input_container_style do
      "display:flex;gap:8px;padding:12px;border-top:1px solid #e0e0e0;background:#fafafa;"
    end

    defp input_style do
      "flex:1;padding:8px 12px;border:1px solid #ddd;border-radius:20px;outline:none;font-size:14px;"
    end

    defp button_style do
      "padding:8px 20px;background:#0084ff;color:white;border:none;border-radius:20px;cursor:pointer;font-size:14px;"
    end
  end
end
