defmodule Claw.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Claw — ADK Elixir Chat</title>
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body { font-family: system-ui, -apple-system, sans-serif; background: #f5f5f5; height: 100vh; }
        </style>
        <script defer phx-track-static src="https://cdn.jsdelivr.net/npm/phoenix@1.7.18/priv/static/phoenix.min.js"></script>
        <script defer phx-track-static src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.0.4/priv/static/phoenix_live_view.min.js"></script>
        <script>
          // Initialize LiveView
          window.addEventListener("DOMContentLoaded", () => {
            let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
            let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: { _csrf_token: csrfToken }
            });
            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
