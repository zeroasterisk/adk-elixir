defmodule Claw.ChatLive do
  @moduledoc """
  LiveView chat interface for Claw — full ADK showcase.

  Demonstrates:
  - **RunConfig** — temperature slider controls generation at runtime
  - **Memory** — sessions persist context via ADK.Memory.InMemory
  - **Artifacts** — save_note/list_notes tools show artifact storage
  - **LongRunningTool** — research tool streams progress to UI
  - **Auth/Credentials** — call_mock_api tool shows credential flow
  """

  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    session_id = "lv-session-#{System.unique_integer([:positive])}"

    socket =
      socket
      |> assign(:agent, Claw.Agents.router())
      |> assign(:app_name, "claw")
      |> assign(:page_title, "Claw Chat")
      |> assign(:temperature, 0.7)
      |> assign(:session_id, session_id)
      |> assign(:messages, [])
      |> assign(:loading, false)
      |> assign(:input_value, "")
      |> assign(:streaming_msg_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => msg}, socket) when msg != "" do
    temperature = socket.assigns.temperature
    run_config = Claw.Agents.run_config(temperature: temperature)
    runner = Claw.Agents.runner()

    user_msg = %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: "user",
      author: "You",
      text: msg
    }

    # Create a placeholder for the streaming agent response
    stream_id = "msg-#{System.unique_integer([:positive])}"
    stream_placeholder = %{
      id: stream_id,
      role: "agent",
      author: "claw",
      text: "",
      streaming: true
    }

    socket =
      socket
      |> update(:messages, &(&1 ++ [user_msg, stream_placeholder]))
      |> assign(:loading, true)
      |> assign(:streaming_msg_id, stream_id)
      |> assign(:input_value, "")

    # Run the agent asynchronously — events arrive as {:adk_event, event} messages
    ADK.Runner.run_async(runner, "user", socket.assigns.session_id, %{text: msg},
      reply_to: self(),
      run_config: run_config
    )

    {:noreply, socket}
  end

  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("form_change", %{"message" => msg}, socket) do
    {:noreply, assign(socket, :input_value, msg)}
  end

  def handle_event("set_temperature", %{"temperature" => temp_str}, socket) do
    temp = String.to_float(temp_str)
    {:noreply, assign(socket, :temperature, temp)}
  end

  @impl true
  def handle_info({:adk_event, event}, socket) do
    # An event arrived from the streaming runner — update the streaming placeholder
    text = extract_text(event.content)
    stream_id = socket.assigns.streaming_msg_id

    if text && String.trim(text) != "" && stream_id && !event.partial do
      socket =
        update(socket, :messages, fn msgs ->
          Enum.map(msgs, fn
            %{id: ^stream_id} = m ->
              # Append text to streaming bubble
              existing = m[:text] || ""
              separator = if existing == "", do: "", else: "\n"
              %{m | text: existing <> separator <> text, author: event.author || "claw"}

            m ->
              m
          end)
        end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:adk_done, _events}, socket) do
    # Streaming complete — finalize the placeholder bubble
    stream_id = socket.assigns.streaming_msg_id

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:streaming_msg_id, nil)
      |> update(:messages, fn msgs ->
        Enum.map(msgs, fn
          %{id: ^stream_id} = m -> Map.delete(m, :streaming)
          m -> m
        end)
      end)

    {:noreply, socket}
  end

  def handle_info({:adk_error, reason}, socket) do
    stream_id = socket.assigns.streaming_msg_id

    error_msg = %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: "error",
      author: "system",
      text: "Error: #{inspect(reason)}"
    }

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:streaming_msg_id, nil)
      |> update(:messages, fn msgs ->
        # Remove the empty streaming placeholder
        msgs
        |> Enum.reject(&(&1[:id] == stream_id && (&1[:text] || "") == ""))
        |> Kernel.++([error_msg])
      end)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 860px; margin: 0 auto; padding: 20px; height: 100vh; display: flex; flex-direction: column; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;">
      <div style="text-align: center; margin-bottom: 12px;">
        <h1 style="color: #333; margin: 0 0 4px;">🦀 Claw</h1>
        <p style="color: #666; font-size: 13px; margin: 0;">
          ADK Elixir full-stack showcase — artifacts · memory · auth · long-running tools
        </p>
      </div>

      <%# RunConfig panel %>
      <div style="background: #f8f9fa; border: 1px solid #e0e0e0; border-radius: 8px; padding: 12px; margin-bottom: 12px; display: flex; align-items: center; gap: 16px; font-size: 13px; color: #555;">
        <span><strong>RunConfig</strong></span>
        <label style="display: flex; align-items: center; gap: 8px;">
          Temperature: <strong><%= @temperature %></strong>
          <input
            type="range"
            min="0.0"
            max="1.0"
            step="0.1"
            value={@temperature}
            phx-change="set_temperature"
            name="temperature"
            style="width: 120px;"
          />
        </label>
        <span style="color: #999; font-size: 12px; margin-left: auto;">
          Session: <%= String.slice(@session_id, -8, 8) %>
        </span>
      </div>

      <%# Quick action hints %>
      <div style="display: flex; gap: 8px; margin-bottom: 12px; flex-wrap: wrap;">
        <.hint_button text="📝 Save a note" msg="Save a note called 'ADK' with content: ADK Elixir is awesome!" />
        <.hint_button text="📋 List notes" msg="List my saved notes" />
        <.hint_button text="🔍 Research" msg="Research the Elixir programming language (quick)" />
        <.hint_button text="🌤️ Mock API" msg="Call the weather endpoint of the mock API" />
      </div>

      <%# Chat area %>
      <div style="flex: 1; min-height: 0;">
        <.chat_widget messages={@messages} loading={@loading} input_value={@input_value} />
      </div>
    </div>
    """
  end

  defp hint_button(assigns) do
    ~H"""
    <button
      phx-click="send_message"
      phx-value-message={@msg}
      style="padding: 4px 10px; background: #e8f4fd; color: #0066cc; border: 1px solid #b3d9f5; border-radius: 16px; font-size: 12px; cursor: pointer; white-space: nowrap;"
    >
      <%= @text %>
    </button>
    """
  end

  defp chat_widget(assigns) do
    ~H"""
    <div id="adk-chat" style="display:flex;flex-direction:column;height:100%;border:1px solid #e0e0e0;border-radius:12px;overflow:hidden;background:white;">
      <div id="adk-chat-messages" style="flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:8px;">
        <%= if @messages == [] do %>
          <div style="text-align:center;color:#aaa;margin-top:40px;font-size:14px;">
            <div style="font-size:40px;margin-bottom:8px;">🦀</div>
            <div>Ask Claw anything, or try the quick actions above!</div>
          </div>
        <% end %>
        <%= for msg <- @messages do %>
          <div id={msg.id} style={message_container_style(msg.role)}>
            <div style={bubble_style(msg.role)}>
              <div style="font-size:11px;color:#999;margin-bottom:2px;"><%= msg.author %></div>
              <div style="white-space:pre-wrap;"><%= msg.text %></div>
            </div>
          </div>
        <% end %>
      </div>

      <%= if @loading do %>
        <div style="padding:8px 16px;color:#999;font-size:13px;">
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
        <button
          type="submit"
          disabled={@loading}
          style="padding:10px 24px;background:#0084ff;color:white;border:none;border-radius:24px;cursor:pointer;font-size:14px;"
        >
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

  defp extract_text(%{parts: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{text: t} when is_binary(t) -> t
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp extract_text(_), do: nil
end
