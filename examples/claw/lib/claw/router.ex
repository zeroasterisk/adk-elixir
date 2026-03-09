defmodule Claw.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Claw.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :a2a do
    plug :accepts, ["json"]
  end

  scope "/", Claw do
    pipe_through :browser

    live "/", ChatLive, :index
  end

  # A2A protocol endpoint — handled via a controller to avoid
  # compile-time evaluation of agent structs containing anonymous functions
  scope "/a2a" do
    pipe_through :a2a

    match :get, "/.well-known/agent.json", Claw.A2AController, :agent_card
    match :post, "/", Claw.A2AController, :rpc
  end
end
