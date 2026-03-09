defmodule ADK.EventActions do
  @moduledoc "Actions attached to an event — state deltas, transfers, escalation."

  @type t :: %__MODULE__{
          state_delta: map(),
          artifact_delta: map(),
          requested_auth_configs: map(),
          transfer_to_agent: String.t() | nil,
          escalate: boolean()
        }

  defstruct state_delta: %{},
            artifact_delta: %{},
            requested_auth_configs: %{},
            transfer_to_agent: nil,
            escalate: false
end
