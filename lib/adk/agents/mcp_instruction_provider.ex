defmodule Adk.Agents.McpInstructionProvider do
  @moduledoc """
  Instruction provider that fetches a prompt from an MCP server.
  """

  @behaviour Adk.Agents.InstructionProvider

  alias Adk.Agents.ReadonlyContext
  #alias Adk.Mcp.SessionManagerImpl

  defstruct connection_params: nil,
            prompt_name: nil,
            mcp_session_manager_mod: nil

  @type t :: %__MODULE__{
          connection_params: term(),
          prompt_name: String.t() | nil,
          mcp_session_manager_mod: module()
        }

  @doc "Create a new MCP instruction provider."
  @spec new(term(), String.t()) :: t()
  def new(connection_params, prompt_name) do
    %__MODULE__{
      connection_params: connection_params,
      prompt_name: prompt_name,
      mcp_session_manager_mod:
        ADK.Config.mcp_session_manager_mod()
    }
  end

  @impl true
  def invoke(%__MODULE__{} = provider, %ReadonlyContext{} = context) do
    with {:ok, session} <-
           provider.mcp_session_manager_mod.new(provider.connection_params)
           |> provider.mcp_session_manager_mod.create_session(),
         {:ok, %{prompts: prompts}} <-
           provider.mcp_session_manager_mod.list_prompts(
             provider.mcp_session_manager_mod,
             session
           ),
         prompt <- Enum.find(prompts, &(&1.name == provider.prompt_name)),
         arguments <- build_arguments(prompt, context),
         {:ok, %{messages: messages}} <-
           provider.mcp_session_manager_mod.get_prompt(
             provider.mcp_session_manager_mod,
             session,
             provider.prompt_name,
             arguments
           ) do
      if Enum.empty?(messages) do
        {:error, "Failed to load MCP prompt '#{provider.prompt_name}'."}
      else
        messages
        |> Enum.filter(&(&1.content.type == "text"))
        |> Enum.map(& &1.content.text)
        |> Enum.join()
      end
    else
      _error ->
        # Handle error case, for now, return an empty string
        ""
    end
  end

  defp build_arguments(nil, _context), do: %{}

  defp build_arguments(prompt, context) do
    (prompt.arguments || [])
    |> Enum.reduce(%{}, fn arg, acc ->
      case Map.get(context.invocation_context.session.state, arg.name) do
        nil -> acc
        value -> Map.put(acc, arg.name, value)
      end
    end)
  end
end
