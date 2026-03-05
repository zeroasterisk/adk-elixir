defmodule ADK.Agent do
  @moduledoc """
  The core agent behaviour. Every agent type implements this.

  An agent spec is a map with:
  - `name` — identifier
  - `description` — human-readable
  - `module` — implementing module
  - `config` — module-specific configuration
  - `sub_agents` — child agents for delegation
  """

  @type t :: %{
          name: String.t(),
          description: String.t(),
          module: module(),
          config: map(),
          sub_agents: [t()]
        }

  @type event_stream :: Enumerable.t()

  @doc "Execute the agent, yielding a stream of events."
  @callback run(ctx :: ADK.Context.t()) :: event_stream()
end
