defmodule Claw.CLI do
  @moduledoc """
  Simple stdin/stdout chat interface for Claw.

  Run with: mix run --no-halt -e "Claw.CLI.main()"
  Or:       mix claw.chat
  """

  def main do
    IO.puts("\n🦀 Claw — ADK Elixir Chat Agent")
    IO.puts("Type your message and press Enter. Ctrl+C to quit.\n")

    agent = Claw.Agents.router()
    runner = ADK.Runner.new(app_name: "claw", agent: agent)

    loop(runner, "user", "cli-session")
  end

  defp loop(runner, user_id, session_id) do
    case IO.gets("you> ") do
      :eof ->
        IO.puts("\nBye! 👋")

      {:error, _} ->
        IO.puts("\nBye! 👋")

      input ->
        message = String.trim(input)

        if message == "" do
          loop(runner, user_id, session_id)
        else
          events = ADK.Runner.run(runner, user_id, session_id, %{text: message})

          # Print agent responses
          for event <- events, event.content do
            text = extract_text(event.content)
            if text && text != "", do: IO.puts("\nclaw> #{text}\n")
          end

          loop(runner, user_id, session_id)
        end
    end
  end

  defp extract_text(%{parts: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{text: t} -> t
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp extract_text(_), do: nil
end
