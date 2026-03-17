defmodule Adk.Mcp.SessionManager do
  @callback new(connection_params :: map()) :: any()
  @callback create_session(manager :: any()) :: {:ok, any()} | {:error, any()}
  @callback list_prompts(manager :: any(), session :: any()) :: {:ok, map()} | {:error, any()}
  @callback get_prompt(manager :: any(), session :: any(), prompt_name :: String.t(), arguments :: map()) :: {:ok, map()} | {:error, any()}
end
