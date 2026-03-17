# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Adk.WebServer.Cors do
  @doc """
  Parses a list of CORS origins, separating them into literal origins and a
  combined regex pattern.
  """
  def parse_origins(nil), do: {:ok, [], nil}
  def parse_origins([]), do: {:ok, [], nil}

  def parse_origins(origins) do
    {literals, regexes} =
      Enum.reduce(origins, {[], []}, fn
        "regex:" <> regex, {literals, regexes} -> {literals, [regex | regexes]}
        literal, {literals, regexes} -> {[literal | literals], regexes}
      end)

    combined_regex =
      case regexes do
        [] -> nil
        _ -> Enum.join(Enum.reverse(regexes), "|")
      end

    {:ok, Enum.reverse(literals), combined_regex}
  end
end
