defmodule Adk.Mcp.SessionManagerImpl do
  @behaviour Adk.Mcp.SessionManager

  defstruct connection_params: nil

  @impl true
  def new(connection_params) do
    %__MODULE__{
      connection_params: connection_params
    }
  end

  @impl true
  def create_session(%__MODULE__{}) do
    # TODO: Implement this
    {:ok, %{}}
  end

  @impl true
  def list_prompts(_manager, _session) do
    # TODO: Implement this
    {:ok, %{}}
  end

  @impl true
  def get_prompt(_manager, _session, _prompt_name, _arguments) do
    # TODO: Implement this
    {:ok, %{}}
  end
end
