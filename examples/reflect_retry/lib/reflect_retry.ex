defmodule ReflectRetryExample do
  @moduledoc """
  Demonstrates the `ADK.Plugin.ReflectRetry` plugin for self-correcting agents.

  The plugin validates agent output and retries with feedback if it doesn't
  meet criteria — enabling the LLM to "reflect" and fix its own mistakes.

  ## Examples

  ### JSON output agent
  Forces the agent to output valid JSON, retrying up to 3 times:

      ReflectRetryExample.json_agent()
      |> ReflectRetryExample.chat("List 3 programming languages with their year of creation")

  ### Quality gate agent
  Ensures responses are substantive (>100 chars, no hedging):

      ReflectRetryExample.quality_agent()
      |> ReflectRetryExample.chat("Explain pattern matching in Elixir")
  """

  @doc "Agent that must respond with valid JSON."
  def json_agent do
    ADK.Agent.LlmAgent.new(
      name: "json_responder",
      model: model(),
      instruction: """
      You are a data assistant. Always respond with valid JSON only.
      No markdown, no explanation — just a JSON object or array.
      """,
      plugins: [
        {ADK.Plugin.ReflectRetry,
         max_retries: 3,
         validator: fn events ->
           text =
             events
             |> Enum.map(&(ADK.Event.text(&1) || ""))
             |> Enum.join("")
             |> String.trim()

           # Strip markdown code fences if present
           cleaned =
             text
             |> String.replace(~r/^```json\s*/m, "")
             |> String.replace(~r/^```\s*/m, "")
             |> String.trim()

           case Jason.decode(cleaned) do
             {:ok, _} -> :ok
             {:error, _} -> {:error, "Response must be valid JSON. No markdown, no explanation — output ONLY a JSON object or array."}
           end
         end}
      ]
    )
  end

  @doc "Agent with a quality gate that rejects short or hedging responses."
  def quality_agent do
    ADK.Agent.LlmAgent.new(
      name: "quality_responder",
      model: model(),
      instruction: """
      You are a knowledgeable technical assistant. Give clear, detailed,
      confident answers. Never say "I don't know" — provide your best
      answer with appropriate caveats if uncertain.
      """,
      plugins: [
        {ADK.Plugin.ReflectRetry,
         max_retries: 2,
         validator: fn events ->
           text =
             events
             |> Enum.map(&(ADK.Event.text(&1) || ""))
             |> Enum.join(" ")

           cond do
             String.length(text) < 100 ->
               {:error, "Response too short — provide a detailed, substantive answer (at least a paragraph)."}

             String.contains?(String.downcase(text), "i don't know") ->
               {:error, "Don't say 'I don't know'. Provide your best answer with caveats if needed."}

             true ->
               :ok
           end
         end}
      ]
    )
  end

  @doc """
  Send a message to an agent and print the response.

  ## Example

      ReflectRetryExample.json_agent() |> ReflectRetryExample.chat("List 3 colors")
  """
  def chat(agent, message) do
    runner = %ADK.Runner{app_name: "reflect_retry_demo", agent: agent}
    events = ADK.Runner.run(runner, "user", "session-1", message)

    response =
      events
      |> Enum.map(&ADK.Event.text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("")

    IO.puts(response)
    response
  end

  defp model do
    System.get_env("ADK_MODEL", "gemini-flash-latest")
  end
end
