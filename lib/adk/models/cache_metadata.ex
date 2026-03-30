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

defmodule ADK.Models.CacheMetadata do
  @moduledoc """
  Metadata for context cache associated with LLM responses.

  This struct stores cache identification, usage tracking, and lifecycle
  information for a particular cache instance. It can be in two states:

  1. **Active cache state**: `cache_name` is set, all fields populated
  2. **Fingerprint-only state**: `cache_name` is nil, only `fingerprint` and
     `contents_count` are set for prefix matching

  ## Fields

    * `cache_name` — full resource name of the cached content, or nil (fingerprint-only)
    * `expire_time` — unix timestamp when the cache expires, or nil
    * `fingerprint` — hash of cacheable contents (instruction + tools + contents)
    * `invocations_used` — number of invocations this cache has been used for, or nil
    * `contents_count` — number of contents (cached or total depending on state)
    * `created_at` — unix timestamp when the cache was created, or nil
  """

  @enforce_keys [:fingerprint, :contents_count]
  defstruct [
    :cache_name,
    :expire_time,
    :fingerprint,
    :invocations_used,
    :contents_count,
    :created_at
  ]

  @type t :: %__MODULE__{
          cache_name: String.t() | nil,
          expire_time: float() | nil,
          fingerprint: String.t(),
          invocations_used: non_neg_integer() | nil,
          contents_count: non_neg_integer(),
          created_at: float() | nil
        }

  @doc """
  Creates a new CacheMetadata from a keyword list or map.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) do
    validate_non_negative!(attrs, :invocations_used)
    validate_non_negative!(attrs, :contents_count)
    struct!(__MODULE__, attrs)
  end

  def new(attrs) when is_map(attrs) do
    validate_non_negative!(attrs, :invocations_used)
    validate_non_negative!(attrs, :contents_count)
    struct!(__MODULE__, attrs)
  end

  defp validate_non_negative!(attrs, key) do
    value = if is_map(attrs), do: Map.get(attrs, key), else: Keyword.get(attrs, key)

    if value != nil and is_number(value) and value < 0 do
      raise ArgumentError, "#{key} must be greater than or equal to 0"
    end

    attrs
  end

  @doc """
  Creates a fingerprint-only CacheMetadata (no active cache).

  This is the state returned when no cache exists yet — only the fingerprint
  and contents count are tracked for future prefix matching.
  """
  @spec fingerprint_only(String.t(), non_neg_integer()) :: t()
  def fingerprint_only(fingerprint, contents_count)
      when is_integer(contents_count) and contents_count >= 0 do
    %__MODULE__{
      fingerprint: fingerprint,
      contents_count: contents_count
    }
  end

  def fingerprint_only(_, _) do
    raise ArgumentError, "contents_count must be greater than or equal to 0"
  end

  @doc """
  Returns true if the cache will expire within 2 minutes.
  """
  @spec expire_soon?(t()) :: boolean()
  def expire_soon?(%__MODULE__{expire_time: nil}), do: false

  def expire_soon?(%__MODULE__{expire_time: expire_time}) do
    buffer_seconds = 120
    now() > expire_time - buffer_seconds
  end

  # Testable clock — can be overridden in tests
  defp now do
    :os.system_time(:second) |> Kernel./(1) |> Kernel.+(0.0)
  end
end

defimpl String.Chars, for: ADK.Models.CacheMetadata do
  def to_string(%{cache_name: nil} = meta) do
    short_fp = String.slice(meta.fingerprint, 0, 8)

    "Fingerprint-only: #{meta.contents_count} contents, fingerprint=#{short_fp}..."
  end

  def to_string(%{expire_time: nil} = meta) do
    cache_id = meta.cache_name |> String.split("/") |> List.last()

    "Cache #{cache_id}: used #{meta.invocations_used} invocations, " <>
      "cached #{meta.contents_count} contents, " <>
      "expires unknown"
  end

  def to_string(meta) do
    cache_id = meta.cache_name |> String.split("/") |> List.last()
    now = :os.system_time(:second)
    minutes_left = (meta.expire_time - now) / 60

    "Cache #{cache_id}: used #{meta.invocations_used} invocations, " <>
      "cached #{meta.contents_count} contents, " <>
      "expires in #{:erlang.float_to_binary(minutes_left + 0.0, [{:decimals, 1}])}min"
  end
end
