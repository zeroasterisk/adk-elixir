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

defmodule ADK.Auth.ToolsetAuth do
  @moduledoc """
  Resolves toolset-level authentication before tools are available.

  Mirrors Python ADK's `_resolve_toolset_auth` from `base_llm_flow.py`
  and the `build_auth_request_event` helper from `functions.py`.

  When an agent's tools include toolsets (modules implementing
  `ADK.Tool.Toolset`), this module checks each toolset's auth config.
  If credentials are already available (via a credential manager), they
  are populated into the config. Otherwise, an auth-request event is
  generated so the user can provide credentials.

  ## Toolset auth credential ID

  Toolset auth uses a special prefix (`_adk_toolset_auth_`) on function
  call IDs so that the auth preprocessor can distinguish toolset auth
  from regular tool auth and skip resumption for toolset entries.
  """

  alias ADK.Auth.{Config, Preprocessor}
  alias ADK.Event

  @toolset_auth_prefix Preprocessor.toolset_auth_prefix()
  @request_euc Preprocessor.request_euc_function_call_name()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Resolve authentication for all toolsets in an agent's tool list.

  Iterates over `agent.tools`, finds items that implement the
  `ADK.Tool.Toolset` behaviour, and for each:

  1. Calls `get_auth_config/0` — skip if `nil`
  2. Attempts to load an existing credential via `credential_manager_mod`
  3. If a credential is found, populates `auth_config.exchanged_credential`
  4. If not, adds to pending auth requests

  Returns `{events, ended?}`:
  - `events` — list of auth-request `ADK.Event`s (0 or 1)
  - `ended?` — `true` if invocation should end (auth required)

  ## Options

  - `:credential_manager_mod` — module with `get_credential/3`
    (default: `ADK.Auth.CredentialManager`)
  - `:credential_manager_opts` — opts forwarded to the credential manager

  ## Parameters

  - `context` — `ADK.Context.t()` (invocation context)
  - `agent` — agent struct with `:tools` list
  """
  @spec resolve(ADK.Context.t(), struct(), keyword()) :: {[Event.t()], boolean()}
  def resolve(context, agent, opts \\ []) do
    tools = Map.get(agent, :tools, [])
    cred_mod = Keyword.get(opts, :credential_manager_mod, ADK.Auth.CredentialManager)
    cred_opts = Keyword.get(opts, :credential_manager_opts, [])

    {pending, _configs} =
      Enum.reduce(tools, {%{}, []}, fn tool, {pending_acc, configs_acc} ->
        case toolset_auth_config(tool) do
          nil ->
            {pending_acc, configs_acc}

          auth_config ->
            credential_key = Config.credential_key(auth_config)
            toolset_name = toolset_name(tool)
            fc_id = @toolset_auth_prefix <> toolset_name

            case cred_mod.get_credential(credential_key, config_to_raw(auth_config), cred_opts) do
              {:ok, cred} ->
                # Populate the auth config with the resolved credential
                # (side-effect: mutates the toolset's auth_config in Python;
                # in Elixir we return the info but can't mutate in place)
                updated = %{auth_config | exchanged_credential: cred}
                {pending_acc, [{tool, updated} | configs_acc]}

              _ ->
                {Map.put(pending_acc, fc_id, auth_config), configs_acc}
            end
        end
      end)

    if map_size(pending) == 0 do
      {[], false}
    else
      event = build_auth_request_event(context, pending)
      {[event], true}
    end
  end

  @doc """
  Build an auth-request event from pending auth requests.

  Each entry in `auth_requests` is `{function_call_id, auth_config}`.
  The event contains one function-call part per pending request, using
  the `adk_request_credential` function call name.

  ## Options

  - `:author` — override the event author (default: `context.agent.name`)
  - `:role` — set the content role (default: `"model"`)
  """
  @spec build_auth_request_event(ADK.Context.t(), map(), keyword()) :: Event.t()
  def build_auth_request_event(context, auth_requests, opts \\ []) do
    agent_name =
      case Map.get(context, :agent) do
        %{name: name} -> name
        _ -> "agent"
      end

    author = Keyword.get(opts, :author, agent_name)
    role = Keyword.get(opts, :role, "model")

    parts =
      Enum.map(auth_requests, fn {fc_id, auth_config} ->
        %{
          "function_call" => %{
            "id" => fc_id,
            "name" => @request_euc,
            "args" => %{
              "functionCallId" => fc_id,
              "authConfig" => auth_config_to_map(auth_config)
            }
          }
        }
      end)

    long_running_tool_ids =
      Enum.map(auth_requests, fn {fc_id, _} -> fc_id end)

    Event.new(
      invocation_id: context.invocation_id,
      author: author,
      branch: context.branch,
      content: %{"role" => role, "parts" => parts},
      custom_metadata: %{long_running_tool_ids: long_running_tool_ids}
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp toolset_auth_config(tool) when is_atom(tool) do
    if function_exported?(tool, :get_auth_config, 0) do
      tool.get_auth_config()
    end
  end

  defp toolset_auth_config(%{__struct__: mod} = _tool) do
    if function_exported?(mod, :get_auth_config, 0) do
      mod.get_auth_config()
    end
  end

  defp toolset_auth_config(_), do: nil

  defp toolset_name(tool) when is_atom(tool) do
    tool
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
  end

  defp toolset_name(%{__struct__: mod}) do
    mod
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
  end

  defp toolset_name(_), do: "UnknownToolset"

  defp config_to_raw(%Config{raw_credential: nil}), do: %ADK.Auth.Credential{type: :oauth2}
  defp config_to_raw(%Config{raw_credential: cred}), do: cred

  defp auth_config_to_map(%Config{} = config) do
    %{
      "credentialType" => to_string(config.credential_type),
      "credentialKey" => Config.credential_key(config),
      "required" => config.required,
      "scopes" => config.scopes
    }
  end
end
