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

defmodule ADK.Auth.Refresher do
  @moduledoc """
  Behaviour for credential refreshers.

  A credential refresher checks whether a credential is expired or stale and,
  if so, obtains a fresh version. For example, using an OAuth2 refresh token to
  get a new access token.

  Mirrors Python ADK's `BaseCredentialRefresher`.

  ## Implementing

      defmodule MyRefresher do
        @behaviour ADK.Auth.Refresher

        @impl true
        def refresh_needed?(credential, _scheme), do: {:ok, true}

        @impl true
        def refresh(credential, _scheme) do
          {:ok, %{credential | access_token: "refreshed"}}
        end
      end
  """

  @doc """
  Check whether the given credential needs a refresh.

  Returns `{:ok, boolean}` or `{:error, reason}`.
  """
  @callback refresh_needed?(credential :: map(), scheme :: map() | nil) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  Refresh the credential, returning a new credential with updated tokens.

  Returns `{:ok, refreshed_credential}` or `{:error, reason}`.
  """
  @callback refresh(credential :: map(), scheme :: map() | nil) ::
              {:ok, map()} | {:error, term()}
end
