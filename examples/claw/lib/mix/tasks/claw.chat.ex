defmodule Mix.Tasks.Claw.Chat do
  @moduledoc "Start the Claw CLI chat agent: `mix claw.chat`"
  @shortdoc "Chat with Claw in the terminal"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Claw.CLI.main()
  end
end
