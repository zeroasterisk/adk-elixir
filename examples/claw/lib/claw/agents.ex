defmodule Claw.Agents do
  @moduledoc """
  Agent definitions for Claw — ADK Elixir full-stack showcase.

  Architecture:
  - **Router** — top-level orchestrator with all showcase tools
  - **Coder** — code/programming specialist (shell + file tools)
  - **Helper** — general knowledge + datetime + file reading

  ## Showcased Features

  - **Multi-agent** sub-agent delegation via transfer_to_agent
  - **Artifacts** — save_note / list_notes persist data across turns
  - **Auth/Credentials** — call_mock_api demonstrates credential lifecycle
  - **LongRunningTool** — research tool with progress updates
  - **Memory** — agent remembers context from previous sessions (in-memory store)
  - **RunConfig** — callers can pass temperature/max_tokens at runtime
  """

  alias ADK.Agent.LlmAgent
  alias ADK.RunConfig

  @model "gemini-2.0-flash-lite"

  @doc """
  The top-level router agent.

  Pass `run_config:` when running via `ADK.Runner.run/5` to override
  generation parameters at call time:

      run_config = ADK.RunConfig.new(generate_config: %{temperature: 0.2})
      ADK.Runner.run(runner, user_id, session_id, message, run_config: run_config)
  """
  def router do
    LlmAgent.new(
      name: "router",
      model: @model,
      description: "Routes user requests to the right specialist agent",
      instruction: """
      You are Claw, a helpful AI assistant. You have access to many powerful tools:

      **Information:**
      - `datetime` — get current UTC time
      - `read_file` — read files from disk (sandboxed)
      - `shell_command` — run safe read-only shell commands

      **Artifacts (persistent storage):**
      - `save_note` — save a note/document as a persistent artifact
      - `list_notes` — see all saved notes for this session

      **External APIs (with credential management):**
      - `call_mock_api` — demo of authenticated API calls (weather, news, prices)

      **Research (long-running):**
      - `research` — deep multi-source research with progress updates (takes a few seconds)

      You also have specialist sub-agents:
      - `coder` — programming and code questions
      - `helper` — general knowledge and datetime

      Be concise and helpful. Use tools when they'd help. Delegate to specialists when appropriate.
      """,
      tools: Claw.Tools.all(),
      sub_agents: [coder(), helper()]
    )
  end

  @doc """
  Build a runner with all ADK services wired up.

  This is the recommended way to create a fully-featured Claw runner:

      runner = Claw.Agents.runner()
      events = ADK.Runner.run(runner, "user", "session-1", "Hello!")

  ## Options

  - `:run_config` — `ADK.RunConfig.t()` to pass per-run generation config
  """
  def runner(_opts \\ []) do
    agent = router()

    # Use the ADK-managed stores (started by ADK.Application, already running)
    artifact_service = {ADK.Artifact.InMemory, pid: Process.whereis(ADK.Artifact.InMemory)}
    memory_store = {ADK.Memory.InMemory, name: ADK.Memory.InMemory}

    ADK.Runner.new(
      app_name: "claw",
      agent: agent,
      artifact_service: artifact_service,
      memory_store: memory_store
    )
  end

  @doc """
  Build a RunConfig that showcases generation parameter control.

  ## Examples

      # Creative mode — higher temperature
      run_config = Claw.Agents.run_config(temperature: 0.9, max_tokens: 1024)

      # Precise mode — lower temperature
      run_config = Claw.Agents.run_config(temperature: 0.1)

      # Use it:
      events = ADK.Runner.run(runner, user_id, session_id, input, run_config: run_config)
  """
  def run_config(opts \\ []) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens)

    generate_config =
      %{temperature: temperature}
      |> then(fn cfg ->
        if max_tokens, do: Map.put(cfg, :max_output_tokens, max_tokens), else: cfg
      end)

    RunConfig.new(generate_config: generate_config)
  end

  @doc "Specialist for code and programming questions."
  def coder do
    LlmAgent.new(
      name: "coder",
      model: @model,
      description: "Expert at code, programming, and software engineering questions",
      instruction: """
      You are a coding expert. Answer programming questions clearly and concisely.
      Use the shell_command tool to demonstrate or verify code when helpful.
      Use the read_file tool to examine source files when asked.
      """,
      tools: [Claw.Tools.shell_command(), Claw.Tools.read_file()]
    )
  end

  @doc "Specialist for general help, datetime, file operations."
  def helper do
    LlmAgent.new(
      name: "helper",
      model: @model,
      description: "General assistant for datetime, file reading, and misc questions",
      instruction: """
      You are a helpful general assistant. You can check the current time,
      read files, and answer general knowledge questions.
      """,
      tools: [Claw.Tools.datetime(), Claw.Tools.read_file()]
    )
  end
end
