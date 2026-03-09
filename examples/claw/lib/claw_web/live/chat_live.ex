defmodule Claw.ChatLive do
  @moduledoc """
  LiveView chat interface for Claw, using ADK.Phoenix.ChatLive as the engine.

  This is a thin wrapper that configures the agent and delegates to ADK's
  built-in ChatLive component.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    agent = Claw.Agents.router()

    socket =
      socket
      |> assign(:agent, agent)
      |> assign(:app_name, "claw")
      |> assign(:page_title, "Claw Chat")
      |> ADK.Phoenix.ChatLive.init_chat()

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", params, socket) do
    ADK.Phoenix.ChatLive.handle_event("send_message", params, socket)
  end

  def handle_event("form_change", params, socket) do
    ADK.Phoenix.ChatLive.handle_event("form_change", params, socket)
  end

  @impl true
  def handle_info(msg, socket) do
    ADK.Phoenix.ChatLive.handle_info(msg, socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 800px; margin: 0 auto; padding: 20px; height: 100vh; display: flex; flex-direction: column;">
      <h1 style="text-align: center; color: #333; margin-bottom: 16px;">🦀 Claw</h1>
      <p style="text-align: center; color: #666; margin-bottom: 20px; font-size: 14px;">
        ADK Elixir E2E example — multi-agent AI assistant
      </p>

      <div style="flex: 1; min-height: 0;">
        <.chat_widget messages={@messages} loading={@loading} input_value={@input_value} />
      </div>
    </div>
    """
  end

  defp chat_widget(assigns) do
    ~H"""
    <div id="adk-chat" style="display:flex;flex-direction:column;height:100%;border:1px solid #e0e0e0;border-radius:12px;overflow:hidden;background:white;">
      <div id="adk-chat-messages" phx-update="stream" style="flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:8px;">
        <%= for msg <- @messages do %>
          <div id={msg.id} style={message_container_style(msg.role)}>
            <div style={bubble_style(msg.role)}>
              <div style="font-size:11px;color:#999;margin-bottom:2px;">
                <%= role_label(msg) %>
              </div>
              <div style="white-space:pre-wrap;"><%= msg.text %></div>
            </div>
          </div>
        <% end %>
      </div>

      <%= if @loading do %>
        <div style="padding:8px 16px;color:#999;">
          <em>Thinking...</em>
        </div>
      <% end %>

      <form phx-submit="send_message" phx-change="form_change" style="display:flex;gap:8px;padding:12px;border-top:1px solid #e0e0e0;background:#fafafa;">
        <input
          type="text"
          name="message"
          value={@input_value}
          placeholder="Ask Claw anything..."
          autocomplete="off"
          phx-debounce="50"
          style="flex:1;padding:10px 16px;border:1px solid #ddd;border-radius:24px;outline:none;font-size:14px;"
        />
        <button type="submit" disabled={@loading} style="padding:10px 24px;background:#0084ff;color:white;border:none;border-radius:24px;cursor:pointer;font-size:14px;">
          Send
        </button>
      </form>
    </div>
    """
  end

  defp message_container_style("user"), do: "display:flex;justify-content:flex-end;"
  defp message_container_style(_), do: "display:flex;justify-content:flex-start;"

  defp bubble_style("user") do
    "background:#0084ff;color:white;padding:10px 16px;border-radius:18px 18px 4px 18px;max-width:75%;word-wrap:break-word;"
  end

  defp bubble_style("error") do
    "background:#fee;color:#c00;padding:10px 16px;border-radius:18px 18px 18px 4px;max-width:75%;word-wrap:break-word;"
  end

  defp bubble_style(_) do
    "background:#f0f0f0;color:#333;padding:10px 16px;border-radius:18px 18px 18px 4px;max-width:75%;word-wrap:break-word;"
  end

  defp role_label(%{role: "user"}), do: "You"
  defp role_label(%{role: "error"}), do: "Error"
  defp role_label(%{author: author}) when is_binary(author), do: author
  defp role_label(_), do: "Claw"
end
