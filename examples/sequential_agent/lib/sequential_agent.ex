defmodule SequentialAgentExample do
  @moduledoc """
  Sequential pipeline example — a content creation workflow.

  Three agents run in sequence, each building on the previous output:

  1. **Researcher** — gathers key facts about a topic
  2. **Writer** — drafts a blog post from the research
  3. **Editor** — polishes the draft for clarity and tone

  This demonstrates `ADK.Agent.SequentialAgent` for chaining agents
  into a pipeline where each step's output feeds the next.

  ## Usage

      SequentialAgentExample.run("The future of Elixir in AI")
  """

  @doc "Build the 3-stage content pipeline."
  def pipeline do
    ADK.Agent.SequentialAgent.new(
      name: "content_pipeline",
      description: "Research → Write → Edit pipeline",
      sub_agents: [researcher(), writer(), editor()]
    )
  end

  @doc "Run the pipeline on a topic and print results."
  def run(topic) do
    runner = %ADK.Runner{app_name: "content_pipeline", agent: pipeline()}

    message = "Topic: #{topic}"
    events = ADK.Runner.run(runner, "user", "session-1", message)

    events
    |> Enum.map(&ADK.Event.text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn text ->
      IO.puts("\n---\n#{text}")
    end)

    events
  end

  # --- Pipeline stages ---

  defp researcher do
    ADK.Agent.LlmAgent.new(
      name: "researcher",
      model: model(),
      instruction: """
      You are a research assistant. Given a topic, produce 5-7 concise bullet points
      covering the key facts, trends, and interesting angles. Be specific and cite
      concrete examples where possible. Output ONLY the bullet points.
      """
    )
  end

  defp writer do
    ADK.Agent.LlmAgent.new(
      name: "writer",
      model: model(),
      instruction: """
      You are a blog writer. Take the research bullet points from the previous step
      and write a short, engaging blog post (3-4 paragraphs). Use a conversational
      tone. Include a catchy title. Do not add information beyond what was researched.
      """
    )
  end

  defp editor do
    ADK.Agent.LlmAgent.new(
      name: "editor",
      model: model(),
      instruction: """
      You are an editor. Review the blog post draft and improve it:
      - Fix any grammar or clarity issues
      - Ensure the tone is professional yet approachable
      - Add a one-sentence summary at the top
      - Keep the same length — don't expand

      Output the final polished version only.
      """
    )
  end

  defp model do
    System.get_env("ADK_MODEL", "gemini-flash-latest")
  end
end
