defmodule Adk.ReadonlyContext do
  @moduledoc "A read-only snapshot of invocation context for instruction providers."

  defstruct [:invocation_id, :agent_name, :state, :user_id]

  @type t :: %__MODULE__{
          invocation_id: String.t() | nil,
          agent_name: String.t() | nil,
          state: map(),
          user_id: String.t() | nil
        }

  @doc "Build a readonly context from a full invocation context."
  @spec new(map()) :: t()
  def new(invocation_context) do
    %__MODULE__{
      invocation_id: invocation_context.invocation_id,
      agent_name: invocation_context.agent.name,
      state: invocation_context.session.state,
      user_id: invocation_context.user_id
    }
  end
end
