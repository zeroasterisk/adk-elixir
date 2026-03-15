defmodule ADK.Planner.BuiltIn do
  @moduledoc """
  The built-in planner that uses the model's built-in thinking features.
  """
  @behaviour ADK.Planner

  @enforce_keys [:thinking_config]
  defstruct [:thinking_config]

  @type t :: %__MODULE__{
          thinking_config: map()
        }

  @doc """
  Applies the thinking config to the LLM request.
  """
  @spec apply_thinking_config(t(), map()) :: map()
  def apply_thinking_config(%__MODULE__{thinking_config: thinking_config}, request) do
    # In Elixir, request.generate_config holds the config.
    config = request[:generate_config] || %{}
    config = Map.put(config, :thinking_config, thinking_config)
    Map.put(request, :generate_config, config)
  end

  @impl ADK.Planner
  def build_planning_instruction(_ctx, _request), do: nil

  @impl ADK.Planner
  def process_planning_response(_ctx, _parts), do: nil
end
