defmodule Claw.Agents do
  @moduledoc """
  Agent definitions for Claw — a mini AI assistant.

  Architecture:
  - Router agent: decides which specialist to delegate to
  - Coder agent: answers code/programming questions
  - Helper agent: general knowledge, datetime, file reading
  """

  alias ADK.Agent.LlmAgent

  @model "gemini-2.0-flash-lite"

  @doc "The top-level router agent that delegates to specialists."
  def router do
    LlmAgent.new(
      name: "router",
      model: @model,
      description: "Routes user requests to the right specialist agent",
      instruction: """
      You are Claw, a helpful AI assistant. You have access to tools and specialist sub-agents.

      You can:
      - Answer code and programming questions directly (you have a shell tool and file reader)
      - Tell the current date and time
      - Read files from disk
      - Run shell commands (sandboxed — only safe read-only commands)

      Be concise and helpful. Use tools when they'd help answer the question.
      """,
      tools: Claw.Tools.all(),
      sub_agents: [coder(), helper()]
    )
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
