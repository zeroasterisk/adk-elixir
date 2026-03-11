defmodule Claw.CLI do
  @moduledoc """
  Interactive stdin/stdout chat interface for Claw.

  ## Usage

      mix run --no-halt -e "Claw.CLI.main()"
      # Or via alias:
      mix claw.chat

  ## RunConfig

  Pass flags to control generation:

      CLAW_TEMP=0.9 CLAW_MAX_TOKENS=512 mix claw.chat

  Or call `Claw.CLI.main/1` directly:

      Claw.CLI.main(temperature: 0.2, max_tokens: 1024)
  """

  def main(opts \\ []) do
    temperature = String.to_float(System.get_env("CLAW_TEMP", "0.7"))
    max_tokens =
      case System.get_env("CLAW_MAX_TOKENS") do
        nil -> Keyword.get(opts, :max_tokens)
        v -> String.to_integer(v)
      end

    temperature = Keyword.get(opts, :temperature, temperature)

    run_config = Claw.Agents.run_config(temperature: temperature, max_tokens: max_tokens)
    runner = Claw.Agents.runner()

    IO.puts("\n🦀 Claw — ADK Elixir Chat Agent")
    IO.puts("   Model: gemini-2.0-flash-lite | Temp: #{temperature}#{if max_tokens, do: " | Max tokens: #{max_tokens}", else: ""}")
    IO.puts("   Features: artifacts, memory, auth, long-running tools, sub-agents")
    IO.puts("   Type your message and press Enter. Ctrl+C to quit.\n")
    IO.puts("   Try: 'save a note called hello with content Hello World'")
    IO.puts("       'research elixir programming language'")
    IO.puts("       'call the weather api'\n")

    loop(runner, run_config, "user", "cli-session-#{System.unique_integer([:positive])}")
  end

  defp loop(runner, run_config, user_id, session_id) do
    case IO.gets("you> ") do
      :eof ->
        IO.puts("\nBye! 👋")

      {:error, _} ->
        IO.puts("\nBye! 👋")

      input ->
        message = String.trim(input)

        if message == "" do
          loop(runner, run_config, user_id, session_id)
        else
          events = ADK.Runner.run(runner, user_id, session_id, %{text: message},
            run_config: run_config)

          # Print agent responses
          for event <- events, event.content do
            text = extract_text(event.content)

            if text && text != "" do
              author = event.author || "claw"
              IO.puts("\n#{author}> #{text}\n")
            end
          end

          loop(runner, run_config, user_id, session_id)
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
