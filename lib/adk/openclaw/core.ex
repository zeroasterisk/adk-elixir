defmodule ADK.OpenClaw.Core do
  @moduledoc """
  OpenClaw Core Loop and Agent setup.
  """
  use GenServer
  alias ADK.Agent.LoopAgent
  alias ADK.Agent.LlmAgent
  alias ADK.OpenClaw.Tools.FileSystem
  alias ADK.OpenClaw.Tools.ShellExec
  alias ADK.OpenClaw.Tools.MemoryBank

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    IO.puts "OpenClaw Core Initialized."

    tools = [
      FileSystem.read_file(),
      FileSystem.write_file(),
      ShellExec.exec_command(),
      MemoryBank.read_memory(),
      MemoryBank.write_memory(),
      MemoryBank.memory_forget(),
      MemoryBank.memory_correct()
    ]
    
    agent = LoopAgent.new(
      name: "ClawAgent",
      max_iterations: 5,
      sub_agents: [
        LlmAgent.new(
          name: "OpenClawWorker",
          model: "gemini-flash-latest",
          instruction: "You are OpenClaw. You have access to the file system, shell, and memory bank.",
          tools: tools
        )
      ]
    )
    
    {:ok, %{agent: agent}}
  end
end
