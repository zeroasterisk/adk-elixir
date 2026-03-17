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

defmodule ADK.Auth.Exchanger.Registry do
  @moduledoc """
  Registry for credential exchangers.

  Maps credential types (e.g. `:api_key`, `:oauth2`) to modules implementing
  the `ADK.Auth.Exchanger` behaviour. This mirrors Python ADK's
  `CredentialExchangerRegistry`.

  Uses application environment for storage, similar to `ADK.Auth.ProviderRegistry`.

  ## Usage

      ADK.Auth.Exchanger.Registry.register(:api_key, MyApiKeyExchanger)
      ADK.Auth.Exchanger.Registry.get_exchanger(:api_key)
      #=> MyApiKeyExchanger

      ADK.Auth.Exchanger.Registry.get_exchanger(:unknown)
      #=> nil
  """

  alias ADK.Auth.Credential

  @app_key :auth_exchangers

  @doc """
  Registers an exchanger module for a given credential type.
  """
  @spec register(Credential.credential_type(), module() | nil) :: :ok
  def register(credential_type, exchanger_module) when is_atom(credential_type) do
    exchangers = Application.get_env(:adk, @app_key, %{})

    Application.put_env(
      :adk,
      @app_key,
      Map.put(exchangers, credential_type, exchanger_module)
    )
  end

  @doc """
  Gets the registered exchanger module for a given credential type.

  Returns `nil` if no exchanger is registered for the given type.
  """
  @spec get_exchanger(Credential.credential_type()) :: module() | nil
  def get_exchanger(credential_type) when is_atom(credential_type) do
    exchangers = Application.get_env(:adk, @app_key, %{})
    Map.get(exchangers, credential_type)
  end

  @doc """
  Clears all registered exchangers. Useful for testing.
  """
  @spec clear() :: :ok
  def clear do
    Application.delete_env(:adk, @app_key)
  end
end
