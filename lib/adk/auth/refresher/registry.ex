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

defmodule ADK.Auth.Refresher.Registry do
  @moduledoc """
  Registry for credential refreshers.

  Maps credential types (e.g. `:api_key`, `:oauth2`) to modules implementing
  the `ADK.Auth.Refresher` behaviour. This mirrors Python ADK's
  `CredentialRefresherRegistry`.

  Uses application environment for storage, consistent with
  `ADK.Auth.Exchanger.Registry`.

  ## Usage

      ADK.Auth.Refresher.Registry.register(:oauth2, MyOAuth2Refresher)
      ADK.Auth.Refresher.Registry.get_refresher(:oauth2)
      #=> MyOAuth2Refresher

      ADK.Auth.Refresher.Registry.get_refresher(:unknown)
      #=> nil
  """

  alias ADK.Auth.Credential

  @app_key :auth_refreshers

  @doc """
  Registers a refresher module for a given credential type.
  """
  @spec register(Credential.credential_type(), module() | nil) :: :ok
  def register(credential_type, refresher_module) when is_atom(credential_type) do
    refreshers = Application.get_env(:adk, @app_key, %{})

    Application.put_env(
      :adk,
      @app_key,
      Map.put(refreshers, credential_type, refresher_module)
    )
  end

  @doc """
  Gets the registered refresher module for a given credential type.

  Returns `nil` if no refresher is registered for the given type.
  """
  @spec get_refresher(Credential.credential_type()) :: module() | nil
  def get_refresher(credential_type) when is_atom(credential_type) do
    refreshers = Application.get_env(:adk, @app_key, %{})
    Map.get(refreshers, credential_type)
  end

  @doc """
  Clears all registered refreshers. Useful for testing.
  """
  @spec clear() :: :ok
  def clear do
    Application.delete_env(:adk, @app_key)
  end
end
