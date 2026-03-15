defmodule Openclaw.Core do
  use GenServer
  require Logger

  alias ADK.Agent.LlmAgent

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def run(prompt, session_id \\ "default_session") do
    GenServer.call(__MODULE__, {:run, prompt, session_id}, 60_000)
  end

  @impl true
  def init(_opts) do
    Logger.info("Openclaw Core Loop initialized.")

    agent = LlmAgent.new(
      name: "OpenclawAgent",
      model: "gemini-flash-latest",
      instruction: "You are OpenClaw, a helpful system agent."
    )

    {:ok, %{agent: agent}}
  end

  @impl true
  def handle_call({:run, prompt, session_id}, _from, state) do
    runner = ADK.Runner.new(
      app_name: "openclaw",
      agent: state.agent,
      session_store: {ADK.Session.Store.Ecto, [repo: Openclaw.Repo]}
    )

    events = ADK.Runner.run(runner, "user1", session_id, prompt)

    response_text = 
      events
      |> Enum.filter(& &1.type == :run_response)
      |> Enum.flat_map(& &1.data.parts)
      |> Enum.map(& &1.text)
      |> Enum.join("\n")

    {:reply, {:ok, response_text}, state}
  end
end
