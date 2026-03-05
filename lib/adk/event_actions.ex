defmodule ADK.EventActions do
  @moduledoc "Actions attached to an event — state deltas, transfers, escalation."

  @type t :: %__MODULE__{
          state_delta: map(),
          transfer_to_agent: String.t() | nil,
          escalate: boolean()
        }

  defstruct state_delta: %{},
            transfer_to_agent: nil,
            escalate: false
end
