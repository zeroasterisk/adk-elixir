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

defmodule ADK.Auth.Exchanger do
  @moduledoc """
  Behaviour for credential exchangers.

  A credential exchanger transforms one type of credential into another.
  For example, exchanging an OAuth2 authorization code for an access token,
  or exchanging a service account key for a bearer token.

  Mirrors Python ADK's `BaseCredentialExchanger`.

  ## Implementing

      defmodule MyExchanger do
        @behaviour ADK.Auth.Exchanger

        @impl true
        def exchange(credential, _scheme) do
          # Transform credential
          {:ok, %{credential | type: :http_bearer, access_token: "exchanged"}}
        end
      end
  """

  @doc """
  Exchange a credential, optionally using an auth scheme for context.

  Returns `{:ok, new_credential}` on success or `{:error, reason}` on failure.
  """
  @callback exchange(credential :: map(), scheme :: map() | nil) ::
              {:ok, map()} | {:error, term()}
end
