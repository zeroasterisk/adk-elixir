defmodule Mix.Tasks.Adk.Server do
  @moduledoc """
  Starts an ADK development server with a browser-based chat UI.

  Similar to Python ADK's `adk web` / `adk api_server`, this task launches
  a local HTTP server so you can interact with your agent via a web browser
  during development.

  ## Usage

      mix adk.server
      mix adk.server --port 4000 --agent MyApp.MyAgent
      mix adk.server --port 8080 --agent MyApp.MyAgent --model gemini-flash-latest

  ## Options

    * `--port` — HTTP port (default: `4000`)
    * `--agent` — Agent module name (default: builds a demo agent)
    * `--model` — LLM model to use (default: `gemini-flash-latest`)

  ## Endpoints

    * `GET /` — Chat UI (open in browser)
    * `GET /flow` — Agent flow visualizer (topology graph)
    * `GET /control` — Control plane dashboard (telemetry + BEAM metrics)
    * `POST /api/chat` — Send a message, get agent response
    * `GET /api/agent` — Agent info / card

  ## Example

      $ mix adk.server --port 4000 --agent MyApp.MyAgent
      ADK Dev Server running at http://localhost:4000
      Agent: MyApp.MyAgent (model: gemini-flash-latest)
      Press Ctrl+C to stop.

  """

  @shortdoc "Starts an ADK development server with a web chat UI"

  use Mix.Task

  @switches [port: :integer, agent: :string, model: :string]
  @default_port 4000
  @default_model "gemini-flash-latest"

  @impl true
  def run(args) do
    {opts, _argv, _} = OptionParser.parse(args, strict: @switches)

    port = opts[:port] || @default_port
    agent_module = resolve_agent(opts[:agent])
    model = opts[:model] || @default_model

    # Start the application (loads config, starts supervision tree)
    Mix.Task.run("app.start")

    Mix.shell().info("""
    ADK Dev Server running at http://localhost:#{port}
    Agent: #{inspect(agent_module)} (model: #{model})
    Press Ctrl+C to stop.
    """)

    router_opts = [agent: agent_module, model: model, port: port]

    case start_server(port, router_opts) do
      {:ok, _pid} ->
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("Failed to start ADK Dev Server: #{inspect(reason)}")
    end
  end

  @doc false
  def start_server(port, opts) do
    bandit_opts = [
      plug: {ADK.DevServer.Router, opts},
      port: port,
      scheme: :http
    ]

    Bandit.start_link(bandit_opts)
  end

  defp resolve_agent(nil), do: :demo
  defp resolve_agent(module_str) when is_binary(module_str), do: Module.concat([module_str])
end
