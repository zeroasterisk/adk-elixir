defmodule ADK.CLI.AgentChangeHandler do
  @moduledoc """
  Decides whether a file change should trigger an agent reload.

  Elixir equivalent of the Python ADK's `AgentChangeHandler`.
  Watches `.ex`, `.exs`, `.yaml`, and `.yml` files (instead of `.py`).
  """

  @supported_extensions ~w(.ex .exs .yaml .yml)

  @doc """
  Returns `true` if the file extension indicates the agent should be reloaded.

  Supported extensions: #{Enum.join(@supported_extensions, ", ")}

  ## Examples

      iex> ADK.CLI.AgentChangeHandler.should_reload?("lib/my_agent.ex")
      true

      iex> ADK.CLI.AgentChangeHandler.should_reload?("config.json")
      false
  """
  @spec should_reload?(String.t()) :: boolean()
  def should_reload?(file_path) when is_binary(file_path) do
    Path.extname(file_path) in @supported_extensions
  end

  @doc """
  Handles a file change event.

  If `should_reload?/1` returns `true` for the given `file_path`, calls
  `agent_loader.remove_from_cache(state.current_app_name)` and adds the
  app name to `state.runners_to_clean`.

  Returns the (possibly updated) state.

  ## Parameters

    * `file_path` — the path of the changed file
    * `agent_loader` — a module implementing `remove_from_cache/1`
    * `state` — a map with `:current_app_name` and `:runners_to_clean`

  """
  @spec handle_change(String.t(), module(), map()) :: map()
  def handle_change(file_path, agent_loader, state) when is_binary(file_path) do
    if should_reload?(file_path) do
      app_name = state.current_app_name
      agent_loader.remove_from_cache(app_name)

      runners = state.runners_to_clean
      updated = if app_name in runners, do: runners, else: [app_name | runners]

      %{state | runners_to_clean: updated}
    else
      state
    end
  end
end
