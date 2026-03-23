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

defmodule ADK.Tool.Toolset do
  @moduledoc """
  Behaviour for toolsets — collections of tools that may require
  authentication before their tools can be used.

  Mirrors Python ADK's `BaseToolset`. A toolset can optionally declare
  an `ADK.Auth.Config` via `get_auth_config/0`. When a toolset requires
  auth, the runner resolves credentials before making tools available.

  ## Example

      defmodule MyToolset do
        @behaviour ADK.Tool.Toolset

        @impl true
        def get_auth_config, do: %ADK.Auth.Config{credential_type: :oauth2, ...}

        @impl true
        def get_tools(_context), do: [my_tool_1(), my_tool_2()]

        @impl true
        def close, do: :ok
      end
  """

  alias ADK.Auth.Config

  @doc "Returns the auth config for this toolset, or nil if no auth is needed."
  @callback get_auth_config() :: Config.t() | nil

  @doc "Returns the list of tools provided by this toolset."
  @callback get_tools(context :: map() | nil) :: [map()]

  @doc "Clean up resources held by the toolset."
  @callback close() :: :ok

  @doc """
  Checks whether a term implements the Toolset behaviour.

  Returns true for maps/structs that have `get_auth_config/0` and `get_tools/1`.
  """
  @spec toolset?(term()) :: boolean()
  def toolset?(term) when is_atom(term) do
    function_exported?(term, :get_auth_config, 0) and
      function_exported?(term, :get_tools, 1)
  end

  def toolset?(%{__struct__: mod}) do
    function_exported?(mod, :get_auth_config, 0) and
      function_exported?(mod, :get_tools, 1)
  end

  def toolset?(_), do: false
end
