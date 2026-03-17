defmodule Adk.ReadonlyContext do
  defstruct [:invocation_id, :agent_name, :state, :user_id]

  def new(invocation_context) do
    %__MODULE__{
      invocation_id: invocation_context.invocation_id,
      agent_name: invocation_context.agent.name,
      state: invocation_context.session.state,
      user_id: invocation_context.user_id
    }
  end
end
