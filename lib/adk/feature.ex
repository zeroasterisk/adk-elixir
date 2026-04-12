# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Feature do
  @moduledoc """
  Feature flag registry for experimental and in-progress features.

  Provides runtime feature gating similar to Python ADK's `_feature_registry`.
  Features can be enabled/disabled programmatically or via `apply_overrides/1`
  which parses comma-separated feature name strings (for CLI integration).

  ## Priority (highest to lowest)

  1. Programmatic overrides (via `enable/1` / `disable/1`)
  2. Registry defaults

  ## Example

      ADK.Feature.enable(:json_schema_for_func_decl)
      ADK.Feature.enabled?(:json_schema_for_func_decl) #=> true

      ADK.Feature.apply_overrides("JSON_SCHEMA_FOR_FUNC_DECL,COMPUTER_USE")
      ADK.Feature.enabled?(:computer_use) #=> true
  """

  require Logger

  @type feature_name :: atom()
  @type stage :: :wip | :experimental | :stable

  @type feature_config :: %{
          stage: stage(),
          default_on: boolean()
        }

  # Central registry of known features with their configs.
  # Mirrors Python ADK's FeatureName enum + _FEATURE_REGISTRY.
  @registry %{
    agent_config: %{stage: :experimental, default_on: true},
    agent_state: %{stage: :experimental, default_on: true},
    authenticated_function_tool: %{stage: :experimental, default_on: true},
    base_authenticated_tool: %{stage: :experimental, default_on: true},
    big_query_toolset: %{stage: :experimental, default_on: true},
    big_query_tool_config: %{stage: :experimental, default_on: true},
    bigtable_tool_settings: %{stage: :experimental, default_on: true},
    bigtable_toolset: %{stage: :experimental, default_on: true},
    computer_use: %{stage: :experimental, default_on: true},
    data_agent_tool_config: %{stage: :experimental, default_on: true},
    data_agent_toolset: %{stage: :experimental, default_on: true},
    google_credentials_config: %{stage: :experimental, default_on: true},
    google_tool: %{stage: :experimental, default_on: true},
    json_schema_for_func_decl: %{stage: :wip, default_on: false},
    progressive_sse_streaming: %{stage: :experimental, default_on: true},
    pubsub_tool_config: %{stage: :experimental, default_on: true},
    pubsub_toolset: %{stage: :experimental, default_on: true},
    skill_toolset: %{stage: :experimental, default_on: true},
    spanner_toolset: %{stage: :experimental, default_on: true},
    spanner_tool_settings: %{stage: :experimental, default_on: true},
    spanner_vector_store: %{stage: :experimental, default_on: true},
    tool_config: %{stage: :experimental, default_on: true},
    tool_confirmation: %{stage: :experimental, default_on: true},
    pluggable_auth: %{stage: :experimental, default_on: true}
  }

  @doc """
  Returns the list of all known feature names (atoms).
  """
  @spec names() :: [feature_name()]
  def names, do: Map.keys(@registry)

  @doc """
  Returns the config for a known feature, or `nil` if unknown.
  """
  @spec config(feature_name()) :: feature_config() | nil
  def config(name) when is_atom(name), do: Map.get(@registry, name)

  @doc """
  Enable a feature by atom name.

  Raises `ArgumentError` if the feature is not in the registry.
  """
  @spec enable(feature_name()) :: :ok
  def enable(name) when is_atom(name) do
    validate_known!(name)
    overrides = get_overrides()
    Application.put_env(:adk, :feature_overrides, Map.put(overrides, name, true))
    :ok
  end

  @doc """
  Disable a feature by atom name.

  Raises `ArgumentError` if the feature is not in the registry.
  """
  @spec disable(feature_name()) :: :ok
  def disable(name) when is_atom(name) do
    validate_known!(name)
    overrides = get_overrides()
    Application.put_env(:adk, :feature_overrides, Map.put(overrides, name, false))
    :ok
  end

  @doc """
  Check if a feature is currently enabled.

  Priority: programmatic override > registry default.
  Raises `ArgumentError` if the feature is not in the registry.
  """
  @spec enabled?(feature_name()) :: boolean()
  def enabled?(name) when is_atom(name) do
    validate_known!(name)
    overrides = get_overrides()

    case Map.fetch(overrides, name) do
      {:ok, value} -> value
      :error -> Map.fetch!(@registry, name).default_on
    end
  end

  @doc """
  Parse a comma-separated string of feature names and enable them.

  Feature names are uppercased in the string (e.g. `"JSON_SCHEMA_FOR_FUNC_DECL,COMPUTER_USE"`).
  Whitespace is trimmed. Unknown names log a warning and are skipped.
  Empty strings are ignored.

  Returns `{:ok, enabled_count}` with the number of features successfully enabled.
  """
  @spec apply_overrides(String.t()) :: {:ok, non_neg_integer()}
  def apply_overrides(feature_string) when is_binary(feature_string) do
    apply_overrides(feature_string, :enable)
  end

  @doc """
  Parse a comma-separated string of feature names and enable or disable them.

  The `action` parameter controls whether features are enabled or disabled.
  """
  @spec apply_overrides(String.t(), :enable | :disable) :: {:ok, non_neg_integer()}
  def apply_overrides(feature_string, action)
      when is_binary(feature_string) and action in [:enable, :disable] do
    count =
      feature_string
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(0, fn raw_name, acc ->
        atom_name =
          try do
            raw_name |> String.downcase() |> String.to_existing_atom()
          rescue
            ArgumentError -> raw_name |> String.downcase()
          end

        if Map.has_key?(@registry, atom_name) do
          case action do
            :enable -> enable(atom_name)
            :disable -> disable(atom_name)
          end

          acc + 1
        else
          valid =
            @registry
            |> Map.keys()
            |> Enum.map(&Atom.to_string/1)
            |> Enum.map(&String.upcase/1)
            |> Enum.sort()

          Logger.warning(
            "WARNING: Unknown feature '#{raw_name}'. Valid names are: #{Enum.join(valid, ", ")}"
          )

          acc
        end
      end)

    {:ok, count}
  end

  @doc """
  Clear all programmatic overrides. Useful for test isolation.
  """
  @spec clear() :: :ok
  def clear do
    Application.put_env(:adk, :feature_overrides, %{})
    :ok
  end

  # -- Private ---------------------------------------------------------------

  defp get_overrides do
    ADK.Config.feature_overrides()
  end

  defp validate_known!(name) do
    unless Map.has_key?(@registry, name) do
      raise ArgumentError,
            "Unknown feature #{inspect(name)}. Known features: #{inspect(Map.keys(@registry))}"
    end
  end
end
