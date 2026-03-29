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

defmodule ADK.SystemInstruction do
  @moduledoc """
  Renders a system instruction template.
  """

  @doc """
  Render a template string, replacing `{var}` placeholders with values from context.

  ## Examples

      iex> ADK.SystemInstruction.render("Hello {name}", %{name: "world"})
      "Hello world"
  """
  @spec render(String.t(), map()) :: String.t()
  def render(template, context) do
    Regex.replace(~r/\{([^}]+)\}/, template, fn _, var ->
      val =
        case Map.fetch(context, var) do
          {:ok, v} -> v
          :error ->
            try do
              Map.get(context, String.to_existing_atom(var))
            rescue
              ArgumentError -> nil
            end
        end
      serialize(val)
    end)
  end

  defp serialize(val) when is_binary(val), do: val
  defp serialize(val) when is_integer(val), do: to_string(val)
  defp serialize(val) when is_float(val), do: to_string(val)
  defp serialize(val) when is_map(val), do: Jason.encode!(val)
  defp serialize(val), do: inspect(val)
end
