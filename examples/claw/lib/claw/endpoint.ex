defmodule Claw.Endpoint do
  use Phoenix.Endpoint, otp_app: :claw

  @session_options [
    store: :cookie,
    key: "_claw_key",
    signing_salt: "claw_sign",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :claw,
    gzip: false

  plug Plug.RequestId
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug Claw.Router
end
