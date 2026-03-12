defmodule ADK.DevServer.Router do
  @moduledoc """
  Plug router for the ADK development server (`mix adk.server`).

  Serves:
  - `GET /` — Inline HTML chat UI
  - `POST /api/chat` — Run agent, return response as JSON
  - `GET /api/agent` — Agent card / info

  This is a development tool — not intended for production use.
  """

  use Plug.Router

  plug Plug.Logger, log: :debug
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :dispatch

  # ── Chat UI ──────────────────────────────────────────────────────────────────

  get "/" do
    html = chat_html(conn.private[:adk_agent], conn.private[:adk_model])

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  # ── API: agent info ───────────────────────────────────────────────────────────

  get "/api/agent" do
    agent = conn.private[:adk_agent]
    model = conn.private[:adk_model]

    info =
      case agent do
        :demo ->
          %{
            name: "ADK Demo Agent",
            module: "demo",
            model: model,
            description: "Auto-generated demo agent for mix adk.server"
          }

        mod when is_atom(mod) ->
          card = safe_agent_card(mod, model)
          %{name: card[:name] || inspect(mod), module: inspect(mod), model: model} |> Map.merge(card)

        _ ->
          %{name: inspect(agent), module: inspect(agent), model: model}
      end

    json(conn, 200, info)
  end

  # ── API: chat (synchronous) ───────────────────────────────────────────────────

  post "/api/chat" do
    case conn.body_params do
      %{"message" => message} when is_binary(message) and message != "" ->
        agent = conn.private[:adk_agent]
        model = conn.private[:adk_model]
        session_id = conn.body_params["session_id"] || "dev-#{:rand.uniform(999_999)}"
        user_id = conn.body_params["user_id"] || "dev-user"

        case run_agent(agent, model, message, session_id, user_id) do
          {:ok, response, events} ->
            json(conn, 200, %{
              response: response,
              session_id: session_id,
              events: events
            })

          {:error, reason} ->
            json(conn, 500, %{error: inspect(reason)})
        end

      _ ->
        json(conn, 400, %{error: "Missing or empty 'message' field"})
    end
  end

  # ── API: chat/stream (SSE streaming) ─────────────────────────────────────────

  post "/api/chat/stream" do
    case conn.body_params do
      %{"message" => message} when is_binary(message) and message != "" ->
        agent_key = conn.private[:adk_agent]
        model = conn.private[:adk_model]
        session_id = conn.body_params["session_id"] || "dev-#{:rand.uniform(999_999)}"
        user_id = conn.body_params["user_id"] || "dev-user"

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        # Thread conn state through lambdas so chunks accumulate correctly
        # in both real HTTP adapters and Plug.Test (resp_body accumulation).
        {:ok, conn_ref} = Agent.start_link(fn -> conn end)

        send_chunk = fn data ->
          current = Agent.get(conn_ref, & &1)
          case chunk(current, "data: #{Jason.encode!(data)}\n\n") do
            {:ok, updated} -> Agent.update(conn_ref, fn _ -> updated end)
            _ -> :ok
          end
        end

        # Send session_id as first event so client can track it
        send_chunk.(%{type: "session", session_id: session_id})

        try do
          agent = resolve_agent_struct(agent_key, model)
          runner = ADK.Runner.new(app_name: "dev", agent: agent)

          ADK.Runner.run_streaming(
            runner, user_id, session_id, message,
            stop_session: false,
            on_event: fn event ->
              send_chunk.(%{
                type: "event",
                author: event.author,
                event_type: event.type,
                content: format_content(event.content),
                partial: event.partial || false
              })
            end
          )

          send_chunk.(%{type: "done"})
        rescue
          e ->
            send_chunk.(%{type: "error", error: Exception.message(e)})
        end

        final_conn = Agent.get(conn_ref, & &1)
        Agent.stop(conn_ref)
        final_conn

      _ ->
        json(conn, 400, %{error: "Missing or empty 'message' field"})
    end
  end

  # ── Catch-all ────────────────────────────────────────────────────────────────

  match _ do
    json(conn, 404, %{error: "Not found", path: conn.request_path})
  end

  # ── Plug callbacks ────────────────────────────────────────────────────────────

  @impl Plug
  def init(opts) do
    Keyword.validate!(opts, [:agent, :model, :port])
    opts
  end

  @impl Plug
  def call(conn, opts) do
    conn
    |> put_private(:adk_agent, opts[:agent] || :demo)
    |> put_private(:adk_model, opts[:model] || "gemini-flash-latest")
    |> super(opts)
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp resolve_agent_struct(:demo, model) do
    ADK.Agent.LlmAgent.new(
      name: "dev_agent",
      model: model,
      instruction: "You are a helpful development assistant. Be concise and clear."
    )
  end

  defp resolve_agent_struct(agent_module, model) when is_atom(agent_module) do
    if function_exported?(agent_module, :__struct__, 0) do
      struct(agent_module)
    else
      cond do
        function_exported?(agent_module, :agent, 0) -> agent_module.agent()
        function_exported?(agent_module, :new, 0) -> agent_module.new()
        true ->
          ADK.Agent.LlmAgent.new(
            name: Macro.underscore(inspect(agent_module)),
            model: model,
            instruction: "You are a helpful assistant."
          )
      end
    end
  end

  defp run_agent(:demo, model, message, session_id, user_id) do
    agent = resolve_agent_struct(:demo, model)
    do_run(agent, "dev", user_id, session_id, message)
  end

  defp run_agent(agent_module, model, message, session_id, user_id)
       when is_atom(agent_module) do
    agent = resolve_agent_struct(agent_module, model)
    do_run(agent, "dev", user_id, session_id, message)
  end

  defp do_run(agent, app_name, user_id, session_id, message) do
    runner = ADK.Runner.new(app_name: app_name, agent: agent)

    try do
      events = ADK.Runner.run(runner, user_id, session_id, message)
      response = extract_response(events)
      {:ok, response, format_events(events)}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp extract_response(events) do
    events
    |> Enum.filter(fn e -> e.author != "user" end)
    |> Enum.flat_map(fn e ->
      case e.content do
        %{parts: parts} when is_list(parts) ->
          parts
          |> Enum.filter(&match?(%{text: t} when is_binary(t), &1))
          |> Enum.map(& &1.text)

        text when is_binary(text) ->
          [text]

        _ ->
          []
      end
    end)
    |> Enum.join("")
  end

  defp format_events(events) do
    Enum.map(events, fn e ->
      %{
        author: e.author,
        type: e.type,
        content: format_content(e.content)
      }
    end)
  end

  defp format_content(%{parts: parts}) when is_list(parts) do
    Enum.map(parts, fn
      %{text: t} -> %{text: t}
      %{function_call: fc} -> %{function_call: %{name: fc.name}}
      %{function_response: fr} -> %{function_response: %{name: fr.name}}
      other -> inspect(other)
    end)
  end

  defp format_content(text) when is_binary(text), do: text
  defp format_content(other), do: inspect(other)

  defp safe_agent_card(mod, model) do
    if function_exported?(mod, :agent_card, 0) do
      mod.agent_card()
    else
      %{model: model}
    end
  rescue
    _ -> %{model: model}
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # ── Chat UI HTML ──────────────────────────────────────────────────────────────

  defp chat_html(agent, model) do
    agent_name =
      case agent do
        :demo -> "ADK Demo Agent"
        mod -> inspect(mod)
      end

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>ADK Dev Server — #{agent_name}</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: system-ui, sans-serif; background: #0f1117; color: #e2e8f0; height: 100vh; display: flex; flex-direction: column; }
        header { background: #1a1d2e; border-bottom: 1px solid #2d3148; padding: 12px 20px; display: flex; align-items: center; gap: 12px; }
        header h1 { font-size: 1rem; font-weight: 600; color: #7c83fd; }
        header .badge { background: #2d3148; border-radius: 4px; padding: 2px 8px; font-size: 0.75rem; color: #94a3b8; }
        #chat { flex: 1; overflow-y: auto; padding: 20px; display: flex; flex-direction: column; gap: 12px; }
        .msg { max-width: 80%; padding: 10px 14px; border-radius: 12px; line-height: 1.5; font-size: 0.9rem; word-wrap: break-word; }
        .msg.user { background: #3b4fd8; align-self: flex-end; border-radius: 12px 12px 2px 12px; }
        .msg.agent { background: #1e2235; border: 1px solid #2d3148; align-self: flex-start; border-radius: 2px 12px 12px 12px; }
        .msg.system { background: transparent; color: #64748b; align-self: center; font-size: 0.8rem; font-style: italic; }
        .msg.error { background: #3d1515; border: 1px solid #7f1d1d; color: #fca5a5; align-self: flex-start; }
        .events { margin-top: 8px; border-top: 1px solid #2d3148; padding-top: 8px; }
        .event { font-size: 0.75rem; color: #64748b; padding: 2px 0; }
        .event .tool { color: #f59e0b; }
        #input-area { background: #1a1d2e; border-top: 1px solid #2d3148; padding: 16px 20px; display: flex; gap: 10px; }
        #msg-input { flex: 1; background: #0f1117; border: 1px solid #2d3148; border-radius: 8px; padding: 10px 14px; color: #e2e8f0; font-size: 0.9rem; resize: none; min-height: 42px; max-height: 120px; overflow-y: auto; outline: none; }
        #msg-input:focus { border-color: #3b4fd8; }
        #send-btn { background: #3b4fd8; color: white; border: none; border-radius: 8px; padding: 10px 18px; cursor: pointer; font-size: 0.9rem; font-weight: 500; white-space: nowrap; }
        #send-btn:hover { background: #4f5fea; }
        #send-btn:disabled { background: #2d3148; color: #64748b; cursor: not-allowed; }
        .spinner { display: inline-block; width: 14px; height: 14px; border: 2px solid #3b4fd8; border-top-color: transparent; border-radius: 50%; animation: spin 0.7s linear infinite; vertical-align: middle; margin-right: 6px; }
        @keyframes spin { to { transform: rotate(360deg); } }
        .cursor { animation: blink 1s step-end infinite; color: #7c83fd; }
        @keyframes blink { 0%,100% { opacity: 1; } 50% { opacity: 0; } }
        pre { white-space: pre-wrap; font-family: monospace; font-size: 0.85rem; }
        .session-id { font-size: 0.7rem; color: #475569; margin-top: 4px; }
      </style>
    </head>
    <body>
      <header>
        <h1>🤖 ADK Dev Server</h1>
        <span class="badge">#{agent_name}</span>
        <span class="badge">#{model}</span>
      </header>

      <div id="chat">
        <div class="msg system">Chat with your agent. Type a message to begin.</div>
      </div>

      <div id="input-area">
        <textarea id="msg-input" placeholder="Type a message..." rows="1"></textarea>
        <button id="send-btn">Send</button>
      </div>

      <script>
        const chat = document.getElementById('chat');
        const input = document.getElementById('msg-input');
        const btn = document.getElementById('send-btn');
        let sessionId = 'dev-' + Math.random().toString(36).slice(2, 10);

        function escHtml(str) {
          return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        }

        function extractText(content) {
          if (!content) return '';
          if (Array.isArray(content)) {
            return content.filter(p => p.text).map(p => p.text).join('');
          }
          return typeof content === 'string' ? content : '';
        }

        function isTool(content) {
          if (!Array.isArray(content)) return false;
          return content.some(p => p.function_call || p.function_response);
        }

        function addMsg(role) {
          const el = document.createElement('div');
          el.className = 'msg ' + role;
          chat.appendChild(el);
          chat.scrollTop = chat.scrollHeight;
          return el;
        }

        function addSystemMsg(text) {
          const el = addMsg('system');
          el.textContent = text;
          return el;
        }

        async function send() {
          const text = input.value.trim();
          if (!text) return;

          input.value = '';
          input.style.height = 'auto';

          // User bubble
          const userEl = addMsg('user');
          userEl.innerHTML = '<pre>' + escHtml(text) + '</pre>';

          btn.disabled = true;
          btn.innerHTML = '<span class="spinner"></span>Thinking...';

          // Agent streaming bubble
          const agentEl = addMsg('agent');
          const textEl = document.createElement('pre');
          const cursor = document.createElement('span');
          cursor.className = 'cursor';
          cursor.textContent = '▋';
          agentEl.appendChild(textEl);
          agentEl.appendChild(cursor);
          chat.scrollTop = chat.scrollHeight;

          let agentText = '';
          let hasToolCalls = false;
          let eventsDiv = null;

          try {
            const res = await fetch('/api/chat/stream', {
              method: 'POST',
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify({message: text, session_id: sessionId})
            });

            if (!res.ok) {
              agentEl.className = 'msg error';
              textEl.textContent = 'HTTP error: ' + res.status;
              cursor.remove();
              return;
            }

            const reader = res.body.getReader();
            const decoder = new TextDecoder();
            let buffer = '';

            while (true) {
              const {done, value} = await reader.read();
              if (done) break;

              buffer += decoder.decode(value, {stream: true});
              const lines = buffer.split('\\n');
              buffer = lines.pop(); // keep incomplete line

              for (const line of lines) {
                if (!line.startsWith('data: ')) continue;
                let msg;
                try { msg = JSON.parse(line.slice(6)); } catch { continue; }

                if (msg.type === 'session') {
                  sessionId = msg.session_id || sessionId;
                } else if (msg.type === 'event') {
                  const evText = extractText(msg.content);
                  if (evText && !msg.partial) {
                    agentText += (agentText ? '\\n' : '') + evText;
                    textEl.textContent = agentText;
                    chat.scrollTop = chat.scrollHeight;
                  }
                  if (isTool(msg.content)) {
                    if (!eventsDiv) {
                      eventsDiv = document.createElement('div');
                      eventsDiv.className = 'events';
                      agentEl.appendChild(eventsDiv);
                    }
                    (Array.isArray(msg.content) ? msg.content : []).forEach(part => {
                      if (part.function_call) {
                        eventsDiv.innerHTML += '<div class="event">🔧 <span class="tool">Tool call:</span> ' + escHtml(part.function_call.name) + '</div>';
                      }
                      if (part.function_response) {
                        eventsDiv.innerHTML += '<div class="event">✅ <span class="tool">Tool result:</span> ' + escHtml(part.function_response.name) + '</div>';
                      }
                    });
                    hasToolCalls = true;
                  }
                } else if (msg.type === 'done') {
                  if (!agentText) textEl.textContent = '(no text response)';
                } else if (msg.type === 'error') {
                  agentEl.className = 'msg error';
                  textEl.textContent = 'Error: ' + msg.error;
                }
              }
            }
          } catch (err) {
            agentEl.className = 'msg error';
            textEl.textContent = 'Network error: ' + err.message;
          } finally {
            cursor.remove();
            btn.disabled = false;
            btn.textContent = 'Send';
            input.focus();
            chat.scrollTop = chat.scrollHeight;
          }
        }

        btn.addEventListener('click', send);
        input.addEventListener('keydown', e => {
          if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            send();
          }
        });
        input.addEventListener('input', () => {
          input.style.height = 'auto';
          input.style.height = Math.min(input.scrollHeight, 120) + 'px';
        });
        input.focus();
      </script>
    </body>
    </html>
    """
  end
end
