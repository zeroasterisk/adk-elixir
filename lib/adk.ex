defmodule ADK do
  @moduledoc """
  The main entry point for ADK Elixir.

  ## Quick Start

      agent = ADK.new("assistant", model: "test", instruction: "Help the user.")
      ADK.chat(agent, "Hello!")
  """

  @doc "Create a new LLM agent with minimal configuration."
  @spec new(String.t(), keyword()) :: ADK.Agent.LlmAgent.t()
  def new(name, opts \\ []) do
    ADK.Agent.LlmAgent.new(Keyword.merge(opts, name: name))
  end

  @doc "Run an agent and return a list of events."
  @spec run(ADK.Agent.t(), String.t() | map(), keyword()) :: [ADK.Event.t()]
  def run(agent, message, opts \\ []) do
    message = if is_binary(message), do: %{text: message}, else: message
    runner = %ADK.Runner{app_name: opts[:app_name] || "adk_default", agent: agent}
    user_id = opts[:user_id] || "default"
    session_id = opts[:session_id] || generate_id()

    ADK.Runner.run(runner, user_id, session_id, message, opts)
  end

  @doc "Send a message and get the final text response. Blocking."
  @spec chat(ADK.Agent.t(), String.t(), keyword()) :: String.t() | nil
  def chat(agent, message, opts \\ []) do
    run(agent, message, opts)
    |> Enum.filter(&ADK.Event.final_response?/1)
    |> Enum.map(&ADK.Event.text/1)
    |> List.last()
  end

  @doc "Create a sequential pipeline from agents."
  @spec sequential([ADK.Agent.t()], keyword()) :: ADK.Agent.t()
  def sequential(agents, opts \\ []) do
    ADK.Agent.SequentialAgent.new(
      name: opts[:name] || "sequential",
      sub_agents: agents
    )
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
