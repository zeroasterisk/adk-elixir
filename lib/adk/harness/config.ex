defmodule ADK.Harness.Config do
  @moduledoc """
  Configuration struct for `ADK.Harness` execution.

  Parsed from the opts keyword list passed to `ADK.Harness.run/3` or
  `ADK.Harness.start/3`. Provides sane defaults so L1 usage requires
  zero configuration.

  ADK Elixir extension — no Python ADK equivalent exists.
  """

  defstruct [
    :session,
    :priority,
    :token_budget,
    budget: %{},
    guardrails: [],
    hooks: %{},
    feedback: nil
  ]

  @type t :: %__MODULE__{
          budget: map(),
          guardrails: [module() | struct()],
          hooks: map(),
          feedback: map() | nil,
          session: pid() | nil,
          priority: atom() | nil,
          token_budget: map() | nil
        }

  @default_budget %{
    max_tokens: nil,
    max_input_tokens: nil,
    max_output_tokens: nil,
    max_steps: 10,
    max_duration_ms: :timer.minutes(5),
    max_cost_usd: nil
  }

  @doc """
  Build a `Config` from the opts keyword list.

  Merges user-provided budget values with defaults. Unknown keys are ignored.

  ## Examples

      iex> config = ADK.Harness.Config.from_opts([])
      iex> config.budget.max_steps
      10

      iex> config = ADK.Harness.Config.from_opts(budget: %{max_steps: 20})
      iex> config.budget.max_steps
      20
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    budget = Map.merge(@default_budget, Map.new(opts[:budget] || %{}))

    %__MODULE__{
      budget: budget,
      guardrails: opts[:guardrails] || [],
      hooks: opts[:hooks] || %{},
      feedback: opts[:feedback],
      session: opts[:session],
      priority: opts[:priority],
      token_budget: opts[:token_budget]
    }
  end

  @doc """
  Returns the default budget map.

  ## Examples

      iex> defaults = ADK.Harness.Config.default_budget()
      iex> defaults.max_steps
      10
  """
  @spec default_budget() :: map()
  def default_budget, do: @default_budget
end
