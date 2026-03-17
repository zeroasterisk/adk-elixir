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

defmodule ADK.Agents.ContextCacheConfig do
  @moduledoc """
  Configuration for context caching.
  """

  defstruct cache_intervals: 10,
            ttl_seconds: 1800,
            min_tokens: 0

  @type t :: %__MODULE__{
          cache_intervals: integer(),
          ttl_seconds: integer(),
          min_tokens: integer()
        }

  @doc """
  Creates a new ContextCacheConfig.
  """
  def new(opts \\ []) do
    struct(__MODULE__, opts)
    |> validate()
  end

  defp validate(%{cache_intervals: intervals}) when intervals < 1 do
    raise "cache_intervals must be greater than or equal to 1"
  end

  defp validate(%{cache_intervals: intervals}) when intervals > 100 do
    raise "cache_intervals must be less than or equal to 100"
  end

  defp validate(%{ttl_seconds: ttl}) when ttl <= 0 do
    raise "ttl_seconds must be greater than 0"
  end

  defp validate(%{min_tokens: tokens}) when tokens < 0 do
    raise "min_tokens must be greater than or equal to 0"
  end

  defp validate(config), do: config

  @doc """
  Returns the TTL as a string with "s" appended.
  """
  def ttl_string(%{ttl_seconds: ttl}) do
    "#{ttl}s"
  end
end

defimpl String.Chars, for: ADK.Agents.ContextCacheConfig do
  def to_string(config) do
    "ContextCacheConfig(cache_intervals=#{config.cache_intervals}, ttl=#{
      ADK.Agents.ContextCacheConfig.ttl_string(config)
    }, min_tokens=#{config.min_tokens})"
  end
end
