defmodule Adk.Agents.ReadonlyContext do
  defstruct invocation_context: nil

  def new(invocation_context) do
    %__MODULE__{
      invocation_context: invocation_context
    }
  end
end
