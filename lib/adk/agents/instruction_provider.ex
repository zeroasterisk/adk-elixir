defmodule Adk.Agents.InstructionProvider do
  @callback invoke(provider :: any(), context :: Adk.Agents.ReadonlyContext.t()) :: String.t()
end
