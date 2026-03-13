defmodule ADK.EventActions do
  @moduledoc """
  Actions attached to an event — state deltas, transfers, escalation.

  ## Fields

    * `:state_delta` — Key-value pairs to merge into session state.
    * `:artifact_delta` — Artifact changes (filename → version).
    * `:requested_auth_configs` — Auth configs requested by tools (call_id → config).
    * `:transfer_to_agent` — Target agent name for transfer.
    * `:escalate` — Whether the agent is escalating to its parent.
    * `:skip_summarization` — If `true`, this event's content is excluded from
      context compaction/summarization. Mirrors Python ADK's `skip_summarization`.
  """

  @type t :: %__MODULE__{
          state_delta: map(),
          artifact_delta: map(),
          requested_auth_configs: map(),
          transfer_to_agent: String.t() | nil,
          escalate: boolean(),
          skip_summarization: boolean()
        }

  defstruct state_delta: %{},
            artifact_delta: %{},
            requested_auth_configs: %{},
            transfer_to_agent: nil,
            escalate: false,
            skip_summarization: false
end
