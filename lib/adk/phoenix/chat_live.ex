if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ADK.Phoenix.ChatLive do
    @moduledoc """
    Production-quality Phoenix LiveView chat interface for ADK agents.

    Features:
    - **Streaming display** — tokens appear as they arrive via session subscribers
    - **Typing indicators** — visual feedback while the agent is thinking
    - **Tool call visualization** — collapsible display of tool calls and responses
    - **Agent transfer display** — shows when conversations transfer between agents
    - **Message types** — user, agent, system, error messages with distinct styling
    - **Markdown rendering** — basic markdown support in agent responses
    - **LiveView streams** — efficient DOM updates (no deprecated phx-update=append)
    - **Reconnection handling** — graceful recovery from disconnects

    ## Usage

    ### Direct mount via router

        live_session :chat, session: %{"agent" => &MyApp.Agents.assistant/0, "app_name" => "my_app"} do
          live "/chat", ADK.Phoenix.ChatLive
        end

    ### Wrapper LiveView (more control)

        defmodule MyAppWeb.ChatLive do
          use MyAppWeb, :live_view

          def mount(_params, _session, socket) do
            {:ok, ADK.Phoenix.ChatLive.init_chat(socket,
              agent: MyApp.Agents.assistant(),
              app_name: "my_app"
            )}
          end

          defdelegate handle_event(event, params, socket), to: ADK.Phoenix.ChatLive
          defdelegate handle_info(msg, socket), to: ADK.Phoenix.ChatLive
          defdelegate render(assigns), to: ADK.Phoenix.ChatLive
        end

    ## Styling

    All elements have CSS classes (`.adk-chat-*`) for custom styling.
    Inline styles provide a complete default look without requiring Tailwind or external CSS.
    Override with your own CSS targeting the class names.
    """

    use Phoenix.LiveView
    import Phoenix.HTML, only: [raw: 1]

    alias ADK.Event

    # ── Public API ──────────────────────────────────────────────────────

    @doc """
    Initialize chat assigns on a socket.

    ## Options
    - `:agent` — the ADK agent (struct or 0-arity function)
    - `:app_name` — application name for session namespacing
    - `:user_id` — user identifier (default: "anonymous")
    - `:session_id` — session identifier (auto-generated if omitted)
    """
    @spec init_chat(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
    def init_chat(socket, opts \\ []) do
      agent = opts[:agent] || socket.assigns[:agent]
      app_name = opts[:app_name] || socket.assigns[:app_name] || "adk_chat"
      user_id = opts[:user_id] || "anonymous"
      session_id = opts[:session_id] || gen_id("chat")

      socket
      |> stream(:messages, [])
      |> assign(
        agent: agent,
        app_name: app_name,
        user_id: user_id,
        session_id: session_id,
        input_value: "",
        loading: false,
        current_agent: agent_name(agent),
        streaming_message_id: nil,
        streaming_text: "",
        collapsed_tools: MapSet.new(),
        reconnected: false
      )
    end

    # ── Mount ───────────────────────────────────────────────────────────

    @impl true
    def mount(_params, session, socket) do
      agent = resolve_agent(session)
      app_name = session["app_name"] || "adk_chat"

      socket =
        socket
        |> assign(agent: agent, app_name: app_name)
        |> init_chat(agent: agent, app_name: app_name)

      # Subscribe to session events if connected
      if connected?(socket) do
        maybe_subscribe_session(socket)
      end

      {:ok, socket}
    end

    # ── Events ──────────────────────────────────────────────────────────

    @impl true
    def handle_event("send_message", %{"message" => message}, socket) do
      message = String.trim(message)

      if message == "" do
        {:noreply, socket}
      else
        msg_id = gen_id("msg")

        user_msg = %{
          id: msg_id,
          type: :user,
          text: message,
          timestamp: DateTime.utc_now()
        }

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
          |> stream_insert(:messages, user_msg)
          |> assign(loading: true, input_value: "")

        {:noreply, socket}
      end
    end

    def handle_event("send_message", _params, socket), do: {:noreply, socket}

    def handle_event("form_change", %{"message" => value}, socket) do
      {:noreply, assign(socket, :input_value, value)}
    end

    def handle_event("toggle_tool", %{"id" => tool_id}, socket) do
      collapsed = socket.assigns.collapsed_tools

      collapsed =
        if MapSet.member?(collapsed, tool_id),
          do: MapSet.delete(collapsed, tool_id),
          else: MapSet.put(collapsed, tool_id)

      {:noreply, assign(socket, :collapsed_tools, collapsed)}
    end

    def handle_event("key_submit", %{"key" => "Enter", "value" => msg}, socket) do
      handle_event("send_message", %{"message" => msg}, socket)
    end

    def handle_event("key_submit", _params, socket), do: {:noreply, socket}

    # ── Info handlers ───────────────────────────────────────────────────

    @impl true
    def handle_info({:adk_event, %Event{} = event}, socket) do
      socket = process_event(event, socket)
      {:noreply, socket}
    end

    def handle_info({:adk_session_event, %Event{} = event}, socket) do
      # From session subscriber — same handling
      socket = process_event(event, socket)
      {:noreply, socket}
    end

    def handle_info({:adk_done, _events}, socket) do
      socket = finalize_streaming(socket)
      {:noreply, assign(socket, :loading, false)}
    end

    def handle_info({:adk_error, reason}, socket) do
      socket = finalize_streaming(socket)

      error_msg = %{
        id: gen_id("err"),
        type: :error,
        text: format_error(reason),
        timestamp: DateTime.utc_now()
      }

      socket =
        socket
        |> stream_insert(:messages, error_msg)
        |> assign(loading: false)

      {:noreply, socket}
    end

    def handle_info(_msg, socket), do: {:noreply, socket}

    # ── Event Processing ────────────────────────────────────────────────

    defp process_event(%Event{} = event, socket) do
      socket
      |> maybe_show_transfer(event)
      |> maybe_show_tool_calls(event)
      |> maybe_show_tool_responses(event)
      |> maybe_show_text(event)
    end

    defp maybe_show_transfer(socket, %Event{actions: %{transfer_to_agent: agent}})
         when is_binary(agent) and agent != "" do
      transfer_msg = %{
        id: gen_id("xfer"),
        type: :system,
        text: "Transferred to #{agent}",
        timestamp: DateTime.utc_now()
      }

      socket
      |> stream_insert(:messages, transfer_msg)
      |> assign(:current_agent, agent)
    end

    defp maybe_show_transfer(socket, _event), do: socket

    defp maybe_show_tool_calls(socket, %Event{} = event) do
      case Event.function_calls(event) do
        [] ->
          socket

        calls ->
          Enum.reduce(calls, socket, fn call, acc ->
            tool_msg = %{
              id: gen_id("tool"),
              type: :tool_call,
              name: call[:name] || call.name,
              args: call[:args] || call.args || %{},
              author: event.author,
              timestamp: DateTime.utc_now()
            }

            stream_insert(acc, :messages, tool_msg)
          end)
      end
    end

    defp maybe_show_tool_responses(socket, %Event{} = event) do
      case Event.function_responses(event) do
        [] ->
          socket

        responses ->
          Enum.reduce(responses, socket, fn resp, acc ->
            resp_msg = %{
              id: gen_id("tres"),
              type: :tool_response,
              name: resp[:name] || resp.name,
              response: resp[:response] || resp.response || %{},
              timestamp: DateTime.utc_now()
            }

            stream_insert(acc, :messages, resp_msg)
          end)
      end
    end

    defp maybe_show_text(socket, %Event{partial: true} = event) do
      text = Event.text(event)
      if text && text != "" do
        update_streaming(socket, event, text)
      else
        socket
      end
    end

    defp maybe_show_text(socket, %Event{} = event) do
      text = Event.text(event)
      if text && text != "" do
        socket = finalize_streaming(socket)

        agent_msg = %{
          id: gen_id("agent"),
          type: :agent,
          text: text,
          author: event.author,
          timestamp: DateTime.utc_now()
        }

        stream_insert(socket, :messages, agent_msg)
      else
        socket
      end
    end

    defp update_streaming(socket, event, text) do
      case socket.assigns.streaming_message_id do
        nil ->
          msg_id = gen_id("stream")

          msg = %{
            id: msg_id,
            type: :agent,
            text: text,
            author: event.author,
            streaming: true,
            timestamp: DateTime.utc_now()
          }

          socket
          |> stream_insert(:messages, msg)
          |> assign(streaming_message_id: msg_id, streaming_text: text)

        msg_id ->
          new_text = socket.assigns.streaming_text <> text

          msg = %{
            id: msg_id,
            type: :agent,
            text: new_text,
            author: event.author,
            streaming: true,
            timestamp: DateTime.utc_now()
          }

          socket
          |> stream_insert(:messages, msg)
          |> assign(streaming_text: new_text)
      end
    end

    defp finalize_streaming(%{assigns: %{streaming_message_id: nil}} = socket), do: socket

    defp finalize_streaming(socket) do
      msg_id = socket.assigns.streaming_message_id
      text = socket.assigns.streaming_text

      msg = %{
        id: msg_id,
        type: :agent,
        text: text,
        author: nil,
        streaming: false,
        timestamp: DateTime.utc_now()
      }

      socket
      |> stream_insert(:messages, msg)
      |> assign(streaming_message_id: nil, streaming_text: "")
    end

    # ── Render ──────────────────────────────────────────────────────────

    @impl true
    def render(assigns) do
      ~H"""
      <div id="adk-chat" class="adk-chat" style={container_style()}>
        <style><%= raw(css_animations()) %></style>

        <div class="adk-chat-header" style={header_style()}>
          <div style="font-weight:600;font-size:15px;">
            <%= @current_agent %>
          </div>
          <div style="font-size:12px;color:#8e8e93;">
            <%= if @loading, do: "typing...", else: "online" %>
          </div>
        </div>

        <div
          id="adk-chat-messages"
          class="adk-chat-messages"
          phx-update="stream"
          style={messages_style()}
        >
          <div :for={{dom_id, msg} <- @streams.messages} id={dom_id} style="width:100%;">
            <%= case msg.type do %>
              <% :user -> %>
                <.user_message msg={msg} />
              <% :agent -> %>
                <.agent_message msg={msg} />
              <% :system -> %>
                <.system_message msg={msg} />
              <% :error -> %>
                <.error_message msg={msg} />
              <% :tool_call -> %>
                <.tool_call_message msg={msg} collapsed={MapSet.member?(@collapsed_tools, msg.id)} />
              <% :tool_response -> %>
                <.tool_response_message msg={msg} collapsed={MapSet.member?(@collapsed_tools, msg.id)} />
            <% end %>
          </div>
        </div>

        <%= if @loading do %>
          <div class="adk-chat-typing" style={typing_indicator_style()}>
            <div style={typing_dots_style()}>
              <span class="adk-dot adk-dot-1">●</span>
              <span class="adk-dot adk-dot-2">●</span>
              <span class="adk-dot adk-dot-3">●</span>
            </div>
            <span style="margin-left:8px;font-size:13px;color:#8e8e93;">
              <%= @current_agent %> is thinking…
            </span>
          </div>
        <% end %>

        <form
          phx-submit="send_message"
          phx-change="form_change"
          class="adk-chat-input"
          style={input_container_style()}
        >
          <input
            type="text"
            name="message"
            value={@input_value}
            placeholder="Type a message…"
            autocomplete="off"
            style={input_style()}
            phx-debounce="50"
          />
          <button type="submit" disabled={@loading} style={button_style(@loading)}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <line x1="22" y1="2" x2="11" y2="13"></line>
              <polygon points="22 2 15 22 11 13 2 9 22 2"></polygon>
            </svg>
          </button>
        </form>
      </div>
      """
    end

    # ── Function components ─────────────────────────────────────────────

    defp user_message(assigns) do
      ~H"""
      <div class="adk-chat-message adk-chat-message--user" style={msg_row_style("user")}>
        <div style={bubble_style("user")}>
          <%= @msg.text %>
        </div>
      </div>
      """
    end

    defp agent_message(assigns) do
      ~H"""
      <div class="adk-chat-message adk-chat-message--agent" style={msg_row_style("agent")}>
        <%= if @msg[:author] do %>
          <div style="font-size:11px;color:#8e8e93;margin-bottom:2px;margin-left:4px;">
            <%= @msg.author %>
          </div>
        <% end %>
        <div style={bubble_style("agent")}>
          <%= raw(render_markdown(@msg.text)) %>
          <%= if @msg[:streaming] do %>
            <span class="adk-cursor">▊</span>
          <% end %>
        </div>
      </div>
      """
    end

    defp system_message(assigns) do
      ~H"""
      <div class="adk-chat-message adk-chat-message--system" style={system_msg_style()}>
        <span style="font-size:12px;color:#8e8e93;">⟳ <%= @msg.text %></span>
      </div>
      """
    end

    defp error_message(assigns) do
      ~H"""
      <div class="adk-chat-message adk-chat-message--error" style={msg_row_style("error")}>
        <div style={bubble_style("error")}>
          ⚠ <%= @msg.text %>
        </div>
      </div>
      """
    end

    defp tool_call_message(assigns) do
      ~H"""
      <div class="adk-chat-message adk-chat-message--tool" style={tool_msg_style()}>
        <div
          phx-click="toggle_tool"
          phx-value-id={@msg.id}
          style="cursor:pointer;display:flex;align-items:center;gap:6px;font-size:13px;color:#6b7280;"
        >
          <span style="font-size:11px;"><%= if @collapsed, do: "▶", else: "▼" %></span>
          <span style="font-size:14px;">🔧</span>
          <span style="font-weight:500;color:#4b5563;"><%= @msg.name %></span>
          <span style="font-size:11px;color:#9ca3af;">called</span>
        </div>
        <%= unless @collapsed do %>
          <pre style={tool_detail_style()}><%= format_json(@msg.args) %></pre>
        <% end %>
      </div>
      """
    end

    defp tool_response_message(assigns) do
      ~H"""
      <div class="adk-chat-message adk-chat-message--tool-response" style={tool_msg_style()}>
        <div
          phx-click="toggle_tool"
          phx-value-id={@msg.id}
          style="cursor:pointer;display:flex;align-items:center;gap:6px;font-size:13px;color:#6b7280;"
        >
          <span style="font-size:11px;"><%= if @collapsed, do: "▶", else: "▼" %></span>
          <span style="font-size:14px;">📋</span>
          <span style="font-weight:500;color:#4b5563;"><%= @msg.name %></span>
          <span style="font-size:11px;color:#9ca3af;">result</span>
        </div>
        <%= unless @collapsed do %>
          <pre style={tool_detail_style()}><%= format_json(@msg.response) %></pre>
        <% end %>
      </div>
      """
    end

    # ── Helpers ─────────────────────────────────────────────────────────

    defp resolve_agent(%{"agent" => agent}) when is_function(agent, 0), do: agent.()
    defp resolve_agent(%{"agent" => agent}), do: agent

    defp resolve_agent(%{"agent_mod" => mod, "agent_fun" => fun}) do
      apply(mod, fun, [])
    end

    defp resolve_agent(_) do
      raise ArgumentError,
            "ADK.Phoenix.ChatLive requires an agent. " <>
              "Pass %{\"agent\" => agent} or %{\"agent_mod\" => mod, \"agent_fun\" => fun}."
    end

    defp agent_name(%{name: name}) when is_binary(name), do: name
    defp agent_name(%{name: name}) when is_atom(name) and not is_nil(name), do: to_string(name)
    defp agent_name(_), do: "Agent"

    defp maybe_subscribe_session(socket) do
      %{app_name: app, user_id: user, session_id: sid} = socket.assigns

      case ADK.Session.lookup(app, user, sid) do
        {:ok, pid} -> ADK.Session.subscribe(pid)
        :error -> :ok
      end
    end

    defp format_error({%{message: msg}, _stacktrace}), do: msg
    defp format_error({exception, _stacktrace}) when is_exception(exception), do: Exception.message(exception)
    defp format_error(reason), do: inspect(reason)

    defp format_json(data) when is_binary(data), do: data

    defp format_json(data) do
      case Jason.encode(data, pretty: true) do
        {:ok, json} -> json
        _ -> inspect(data, pretty: true)
      end
    end

    @doc false
    def render_markdown(text) when is_binary(text) do
      text
      |> escape_html()
      |> convert_code_blocks()
      |> convert_inline_code()
      |> convert_bold()
      |> convert_italic()
      |> convert_links()
      |> convert_newlines()
    end

    def render_markdown(_), do: ""

    defp escape_html(text) do
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
    end

    defp convert_code_blocks(text) do
      Regex.replace(~r/```(\w*)\n(.*?)```/s, text, fn _, _lang, code ->
        ~s(<pre style="background:#1e1e1e;color:#d4d4d4;padding:12px;border-radius:6px;overflow-x:auto;font-size:13px;margin:8px 0;"><code>#{code}</code></pre>)
      end)
    end

    defp convert_inline_code(text) do
      Regex.replace(~r/`([^`]+)`/, text, fn _, code ->
        ~s(<code style="background:#f3f4f6;padding:2px 5px;border-radius:3px;font-size:13px;">#{code}</code>)
      end)
    end

    defp convert_bold(text), do: Regex.replace(~r/\*\*(.+?)\*\*/, text, "<strong>\\1</strong>")
    defp convert_italic(text), do: Regex.replace(~r/\*(.+?)\*/, text, "<em>\\1</em>")

    defp convert_links(text) do
      Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, text, fn _, label, url ->
        ~s(<a href="#{url}" target="_blank" style="color:#0084ff;text-decoration:underline;">#{label}</a>)
      end)
    end

    defp convert_newlines(text), do: String.replace(text, "\n", "<br/>")

    defp gen_id(prefix) do
      "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    end

    # ── Styles ──────────────────────────────────────────────────────────

    defp css_animations do
      """
      @keyframes adk-blink {
        0%, 80%, 100% { opacity: 0.3; }
        40% { opacity: 1; }
      }
      @keyframes adk-cursor-blink {
        0%, 100% { opacity: 1; }
        50% { opacity: 0; }
      }
      .adk-dot { animation: adk-blink 1.4s infinite; font-size: 14px; color: #8e8e93; }
      .adk-dot-1 { animation-delay: 0s; }
      .adk-dot-2 { animation-delay: 0.2s; }
      .adk-dot-3 { animation-delay: 0.4s; }
      .adk-cursor { animation: adk-cursor-blink 1s infinite; color: #8e8e93; font-size: 14px; }
      #adk-chat-messages { scroll-behavior: smooth; }
      """
    end

    defp container_style do
      "display:flex;flex-direction:column;height:100%;max-height:700px;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,0.08);"
    end

    defp header_style do
      "padding:14px 18px;border-bottom:1px solid #e5e7eb;background:#fafafa;display:flex;justify-content:space-between;align-items:center;"
    end

    defp messages_style do
      "flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:4px;background:#fff;"
    end

    defp msg_row_style("user"), do: "display:flex;flex-direction:column;align-items:flex-end;padding:2px 0;"
    defp msg_row_style(_), do: "display:flex;flex-direction:column;align-items:flex-start;padding:2px 0;"

    defp bubble_style("user") do
      "background:#0084ff;color:#fff;padding:10px 16px;border-radius:18px 18px 4px 18px;max-width:75%;word-wrap:break-word;font-size:14px;line-height:1.45;"
    end

    defp bubble_style("error") do
      "background:#fef2f2;color:#991b1b;padding:10px 16px;border-radius:18px 18px 18px 4px;max-width:75%;word-wrap:break-word;font-size:14px;line-height:1.45;border:1px solid #fecaca;"
    end

    defp bubble_style(_) do
      "background:#f3f4f6;color:#1f2937;padding:10px 16px;border-radius:18px 18px 18px 4px;max-width:75%;word-wrap:break-word;font-size:14px;line-height:1.45;"
    end

    defp system_msg_style do
      "display:flex;justify-content:center;padding:8px 0;"
    end

    defp tool_msg_style do
      "padding:6px 12px;margin:2px 0;background:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;max-width:85%;"
    end

    defp tool_detail_style do
      "margin:6px 0 2px;padding:8px;background:#f3f4f6;border-radius:4px;font-size:12px;line-height:1.4;overflow-x:auto;max-height:200px;overflow-y:auto;white-space:pre-wrap;word-break:break-all;"
    end

    defp typing_indicator_style do
      "padding:8px 18px;display:flex;align-items:center;"
    end

    defp typing_dots_style do
      "display:flex;gap:3px;align-items:center;"
    end

    defp input_container_style do
      "display:flex;gap:8px;padding:12px 16px;border-top:1px solid #e5e7eb;background:#fafafa;"
    end

    defp input_style do
      "flex:1;padding:10px 16px;border:1px solid #e5e7eb;border-radius:24px;outline:none;font-size:14px;background:#fff;transition:border-color 0.2s;"
    end

    defp button_style(disabled) do
      bg = if disabled, do: "#93c5fd", else: "#0084ff"
      "padding:10px;background:#{bg};color:#fff;border:none;border-radius:50%;cursor:pointer;display:flex;align-items:center;justify-content:center;width:40px;height:40px;transition:background 0.2s;"
    end
  end
end
