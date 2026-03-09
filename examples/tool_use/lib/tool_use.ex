defmodule ToolUse do
  @moduledoc """
  Multi-tool agent example demonstrating function calling with ADK Elixir.

  This agent has access to several tools:
  - **Calculator** — evaluate math expressions
  - **String utils** — word count, reverse, uppercase
  - **DateTime** — current time in any timezone

  Demonstrates:
  - Defining multiple `FunctionTool`s
  - Pattern matching in tool implementations
  - The agent choosing the right tool based on the question

  ## Usage

      ToolUse.chat("What time is it in Tokyo?")
      ToolUse.chat("How many words are in 'the quick brown fox'?")
      ToolUse.chat("What is 42 * 17 + 3?")
  """

  @doc "Build the multi-tool agent."
  def agent do
    ADK.Agent.LlmAgent.new(
      name: "tool_demo",
      model: model(),
      instruction: """
      You are a helpful assistant with access to several tools.
      Use the calculator for math, string_utils for text manipulation,
      and current_time for time/date queries.
      Always use tools rather than guessing. Be concise.
      """,
      tools: ToolUse.Tools.all()
    )
  end

  @doc """
  Chat with the agent.

  ## Examples

      ToolUse.chat("What's 2^10?")
      ToolUse.chat("Reverse the string 'hello world'")
      ToolUse.chat("What time is it in UTC?")
  """
  def chat(message, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, make_ref() |> inspect())
    user_id = Keyword.get(opts, :user_id, "user")

    runner = %ADK.Runner{app_name: "tool_use_demo", agent: agent()}

    events = ADK.Runner.run(runner, user_id, session_id, message)

    # Extract and print the final text response
    events
    |> Enum.map(&ADK.Event.text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> tap(&IO.puts/1)
  end

  defp model do
    System.get_env("ADK_MODEL", "gemini-2.0-flash")
  end
end
