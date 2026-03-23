defmodule Adk.Agents.InstructionProvider do
  @callback invoke(provider :: any(), context :: map()) :: String.t()
end
