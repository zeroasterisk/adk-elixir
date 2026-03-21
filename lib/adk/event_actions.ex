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
    * `:end_of_agent` — If `true`, the current agent has finished its run within
      this invocation. May appear multiple times for the same agent when loops
      are involved. Set by the ADK workflow, not by user code.
  """

  @type t :: %__MODULE__{
          state_delta: map(),
          artifact_delta: map(),
          requested_auth_configs: map(),
          transfer_to_agent: String.t() | nil,
          escalate: boolean(),
          skip_summarization: boolean(),
          end_of_agent: boolean()
        }

  @derive Jason.Encoder
  defstruct state_delta: %{},
            artifact_delta: %{},
            requested_auth_configs: %{},
            transfer_to_agent: nil,
            escalate: false,
            skip_summarization: false,
            end_of_agent: false
end
