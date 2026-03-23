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

defmodule ADK.Tool.Confirmation do
  @moduledoc """
  Represents a tool confirmation configuration.

  Matches the Python ADK `ToolConfirmation` model.
  """

  defstruct hint: "", confirmed: false, payload: nil

  @type t :: %__MODULE__{
          hint: String.t(),
          confirmed: boolean(),
          payload: any()
        }

  @doc "Create a new ToolConfirmation."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end

  @doc "Serialize to JSON-compatible map (camelCase for parity)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = conf) do
    %{
      "hint" => conf.hint,
      "confirmed" => conf.confirmed,
      "payload" => conf.payload
    }
  end

  @doc "Parse from a map (handles both camelCase and snake_case keys)."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      hint: map["hint"] || map[:hint] || "",
      confirmed: Map.get(map, "confirmed") || Map.get(map, :confirmed) || false,
      payload: Map.get(map, "payload") || Map.get(map, :payload)
    }
  end
end
