defmodule CodeExecutionAgent do
  @moduledoc """
  A data analysis agent that can write and execute Elixir code.

  Demonstrates:
  - Stateful code execution via an `Agent` process (bindings persist across calls)
  - Custom tool wrapping `Code.eval_string/3`
  - Interactive REPL-style conversation

  Port of the Python ADK `code_execution/agent.py` sample, which uses
  `BuiltInCodeExecutor`. Here we implement the equivalent using Elixir's
  `Code.eval_string/3` with shared bindings.

  ## Usage

      # Start the executor (bindings store)
      CodeExecutionAgent.Executor.start_link()

      # One-shot
      CodeExecutionAgent.chat("Calculate the mean of [1, 2, 3, 4, 5]")

      # Interactive
      CodeExecutionAgent.interactive()
  """

  @doc "Build the code execution agent."
  def agent do
    ADK.Agent.LlmAgent.new(
      name: "code_execution_agent",
      model: model(),
      instruction: """
      You are a data analysis assistant that can write and execute Elixir code.
      When the user asks you to perform calculations, data transformations, or
      analysis, write Elixir code and execute it using the execute_code tool.

      Key points:
      - Variables you define persist between executions within a session.
      - Use Enum, Stream, Map, and other standard library modules freely.
      - For math, use Kernel arithmetic or the :math module.
      - Return results by making the last expression evaluate to the answer.
      - If code raises an error, read the message and fix your code.

      Be concise. Show the code you ran and explain the result.
      """,
      tools: [CodeExecutionAgent.Executor.tool()],
      description: "A data analysis assistant that executes Elixir code"
    )
  end

  @doc """
  Chat with the agent. Starts the executor automatically if not running.

  ## Examples

      CodeExecutionAgent.chat("What is the sum of the first 100 integers?")
  """
  def chat(message, opts \\ []) do
    ensure_executor!()

    session_id = Keyword.get(opts, :session_id, "default")
    user_id = Keyword.get(opts, :user_id, "user")

    runner = %ADK.Runner{app_name: "code_execution_app", agent: agent()}
    events = ADK.Runner.run(runner, user_id, session_id, message)

    events
    |> Enum.map(&ADK.Event.text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> tap(&IO.puts/1)
  end

  @doc "Run an interactive REPL session."
  def interactive do
    ensure_executor!()

    IO.puts("Code Execution Agent — type 'quit' to exit")
    IO.puts(String.duplicate("=", 50))
    interactive_loop("user1", "session-#{System.unique_integer([:positive])}")
  end

  defp interactive_loop(user_id, session_id) do
    case IO.gets("\nYou: ") do
      :eof -> :ok
      {:error, _} -> :ok
      input ->
        message = String.trim(input)

        if message in ["quit", "exit", "q"] do
          IO.puts("Goodbye!")
        else
          chat(message, session_id: session_id, user_id: user_id)
          interactive_loop(user_id, session_id)
        end
    end
  end

  defp ensure_executor! do
    case Process.whereis(CodeExecutionAgent.Executor) do
      nil -> CodeExecutionAgent.Executor.start_link()
      _pid -> :ok
    end
  end

  defp model do
    System.get_env("ADK_MODEL", "gemini-2.0-flash")
  end
end
