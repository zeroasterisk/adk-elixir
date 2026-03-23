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

defmodule ADK.Agent.BaseAgent do
  @moduledoc """
  Shared utilities for all agent types.

  In ADK Elixir, agents implement the `ADK.Agent` protocol directly rather
  than inheriting from a base class. This module provides common helpers
  (e.g., name validation) used across agent types.

  > **Note:** The `__using__` macro that was here has been removed — it had
  > no callers. Implement `ADK.Agent` directly on your struct instead.
  """

  @name_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_-]*$/

  @doc """
  Validate that an agent name is well-formed.

  Names must start with a letter or underscore and contain only
  alphanumeric characters, underscores, and hyphens.

  ## Examples

      iex> ADK.Agent.BaseAgent.validate_name!("my_agent")
      :ok

      iex> ADK.Agent.BaseAgent.validate_name!("123bad")
      ** (ArgumentError) Invalid agent name "123bad". Must match ~r/^[a-zA-Z_][a-zA-Z0-9_-]*$/
  """
  @spec validate_name!(String.t()) :: :ok
  def validate_name!(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name) do
      :ok
    else
      raise ArgumentError,
            "Invalid agent name #{inspect(name)}. Must match #{inspect(@name_pattern)}"
    end
  end
end
