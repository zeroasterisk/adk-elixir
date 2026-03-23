defmodule Adk.Mcp.SessionManagerImpl do
  @moduledoc """
  Default stub implementation of `Adk.Mcp.SessionManager`.

  All operations return `{:ok, %{}}` — this exists as a placeholder so
  `McpInstructionProvider` has a valid default. Replace with a real
  implementation by setting `:mcp_session_manager_mod` in config.
  """

  @behaviour Adk.Mcp.SessionManager

  defstruct connection_params: nil

  @impl true
  def new(connection_params) do
    %__MODULE__{connection_params: connection_params}
  end

  @impl true
  def create_session(%__MODULE__{}), do: {:ok, %{}}

  @impl true
  def list_prompts(_manager, _session), do: {:ok, %{}}

  @impl true
  def get_prompt(_manager, _session, _prompt_name, _arguments), do: {:ok, %{}}
end
