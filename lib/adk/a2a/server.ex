defmodule ADK.A2A.Server do
  @moduledoc """
  A2A protocol server for ADK agents, implemented as a Plug.

  Wraps the `A2A.Server` from the [a2a](https://github.com/zeroasterisk/a2a-elixir)
  package with ADK-specific handler logic (running agents via `ADK.Runner`).

  Serves the Agent Card at `GET /.well-known/agent.json` and handles
  JSON-RPC 2.0 requests at `POST /`.

  ## Usage

      plug ADK.A2A.Server,
        agent: my_agent_spec,
        runner: %ADK.Runner{app_name: "my_app", agent: my_agent_spec},
        url: "http://localhost:4000/a2a"

  Tasks are stored in an ETS table for simplicity.
  """

  @behaviour Plug
  @behaviour A2A.Handler

  alias ADK.A2A.{AgentCard, Message}

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    # Store ADK-specific config in process dictionary-accessible place
    # We need to pass it through to the A2A.Server
    agent = Keyword.fetch!(opts, :agent)
    runner = Keyword.fetch!(opts, :runner)
    url = Keyword.get(opts, :url, "http://localhost:4000")
    card_opts = Keyword.get(opts, :card_opts, [])

    # Create an ETS table to store our ADK config for the handler
    config_table = :ets.new(:adk_a2a_config, [:set, :public])
    :ets.insert(config_table, {:config, %{agent: agent, runner: runner, card_opts: card_opts}})

    # Initialize the underlying A2A.Server
    a2a_config = A2A.Server.init(
      handler: __MODULE__,
      url: url,
      card_opts: [{:config_table, config_table} | card_opts]
    )

    Map.put(a2a_config, :adk_config_table, config_table)
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, config) do
    # Store ADK config in process dictionary so handler callbacks can access it
    [{:config, adk_config}] = :ets.lookup(config.adk_config_table, :config)
    Process.put(:adk_a2a_config, adk_config)
    A2A.Server.call(conn, config)
  end

  # -- A2A.Handler callbacks --

  @impl A2A.Handler
  def agent_card(opts) do
    adk_config = Process.get(:adk_a2a_config)
    card_opts = Keyword.delete(adk_config.card_opts || [], :config_table)
    AgentCard.to_a2a_card(adk_config.agent, Keyword.merge(card_opts, url: opts.url))
  end

  @impl A2A.Handler
  def handle_task(message_text, params) do
    adk_config = Process.get(:adk_a2a_config)
    user_id = params["sessionId"] || "a2a-user"
    task_id = params["id"] || "a2a-task"
    session_id = params["sessionId"] || "a2a-#{task_id}"

    events = ADK.Runner.run(adk_config.runner, user_id, session_id, message_text)

    # Convert events to A2A messages
    messages = Enum.map(events, &Message.from_event/1)

    # Build artifacts from agent messages
    artifacts =
      messages
      |> Enum.filter(fn m -> m["role"] == "agent" end)
      |> Enum.map(fn m -> %{"parts" => m["parts"]} end)

    # Convert to A2A types
    a2a_messages = Enum.map(messages, &A2A.Message.from_map/1)
    a2a_artifacts = Enum.map(artifacts, &A2A.Artifact.from_map/1)

    {:ok, a2a_messages, a2a_artifacts}
  end
end
