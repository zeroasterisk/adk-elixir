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

defmodule ADK.Auth.FunctionsRequestEucTest do
  @moduledoc """
  Parity tests for Python ADK's `test_functions_request_euc.py`.

  Tests end-user credential (EUC) request flows — tools requesting
  credentials, the auth preprocessor processing responses, and the
  full credential round-trip through the Elixir ADK pipeline.

  Python tests ported:
  - test_function_request_euc → multiple tools request credentials via ToolContext
  - test_function_get_auth_response → full round-trip auth flow with preprocessor
  - test_function_get_auth_response_partial → partial auth response handling
  """
  use ExUnit.Case, async: true

  alias ADK.Auth.{Config, Credential, Preprocessor}
  alias ADK.{Context, Event, EventActions, ToolContext}

  @request_euc Preprocessor.request_euc_function_call_name()

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_ctx(opts \\ []) do
    %Context{
      invocation_id: Keyword.get(opts, :invocation_id, "inv-test"),
      session_pid: nil,
      agent: nil,
      user_content: %{text: "test"},
      callbacks: [],
      policies: [],
      plugins: []
    }
  end

  defp make_tool_ctx(call_id, tool_name) do
    ToolContext.new(make_ctx(), call_id, %{name: tool_name})
  end

  defp make_auth_config(client_id, client_secret, opts \\ []) do
    Config.new(
      credential_type: :oauth2,
      scopes: Keyword.get(opts, :scopes, ["https://www.googleapis.com/auth/calendar"]),
      raw_credential:
        Credential.oauth2(nil,
          client_id: client_id,
          client_secret: client_secret
        ),
      credential_key: Keyword.get(opts, :credential_key)
    )
  end

  defp make_auth_response(client_id, client_secret, access_token, opts \\ []) do
    Config.new(
      credential_type: :oauth2,
      scopes: Keyword.get(opts, :scopes, ["https://www.googleapis.com/auth/calendar"]),
      raw_credential:
        Credential.oauth2(nil,
          client_id: client_id,
          client_secret: client_secret
        ),
      exchanged_credential:
        Credential.oauth2(access_token,
          client_id: client_id,
          client_secret: client_secret
        ),
      credential_key: Keyword.get(opts, :credential_key)
    )
  end

  defp mock_llm_agent do
    %ADK.Agent.LlmAgent{
      name: "root_agent",
      model: "gemini-2.0-flash",
      instruction: "test"
    }
  end

  # Build a user event that returns auth credentials (function responses)
  defp user_auth_response_event(auth_responses) do
    parts =
      Enum.map(auth_responses, fn {fc_id, auth_config} ->
        %{
          "function_response" => %{
            "name" => @request_euc,
            "id" => fc_id,
            "response" => auth_config
          }
        }
      end)

    Event.new(%{
      author: "user",
      content: %{"parts" => parts}
    })
  end

  # Build a system/model event with adk_request_credential function calls
  defp euc_function_call_event(calls) do
    parts =
      Enum.map(calls, fn {euc_fc_id, original_fc_id, auth_config} ->
        %{
          "function_call" => %{
            "name" => @request_euc,
            "id" => euc_fc_id,
            "args" => %{
              "function_call_id" => original_fc_id,
              "auth_config" => auth_config
            }
          }
        }
      end)

    Event.new(%{
      author: "model",
      content: %{"parts" => parts}
    })
  end

  # ---------------------------------------------------------------------------
  # Tests: tool requesting credentials (mirrors test_function_request_euc)
  # ---------------------------------------------------------------------------

  describe "tool request_credential — EUC flow" do
    test "single tool requests a credential and it's recorded in actions" do
      tc = make_tool_ctx("call_1", "call_external_api1")
      auth_config = make_auth_config("oauth_client_id_1", "oauth_client_secret1")

      assert {:ok, tc2} = ToolContext.request_credential(tc, auth_config)

      actions = ToolContext.actions(tc2)
      assert Map.has_key?(actions.requested_auth_configs, "call_1")
      stored = actions.requested_auth_configs["call_1"]
      assert stored.credential_type == :oauth2
      assert stored.raw_credential.client_id == "oauth_client_id_1"
      assert stored.raw_credential.client_secret == "oauth_client_secret1"
    end

    test "two tools request different credentials — both recorded" do
      # Simulate two tools each requesting their own auth config
      # (mirrors Python test_function_request_euc with two tools)
      auth_config1 = make_auth_config("oauth_client_id_1", "oauth_client_secret1")
      auth_config2 = make_auth_config("oauth_client_id_2", "oauth_client_secret2")

      tc1 = make_tool_ctx("call_1", "call_external_api1")
      assert {:ok, tc1_updated} = ToolContext.request_credential(tc1, auth_config1)

      tc2 = make_tool_ctx("call_2", "call_external_api2")
      assert {:ok, tc2_updated} = ToolContext.request_credential(tc2, auth_config2)

      # Each tool context records its own auth config
      actions1 = ToolContext.actions(tc1_updated)
      actions2 = ToolContext.actions(tc2_updated)

      assert Map.has_key?(actions1.requested_auth_configs, "call_1")
      assert Map.has_key?(actions2.requested_auth_configs, "call_2")

      assert actions1.requested_auth_configs["call_1"].raw_credential.client_id ==
               "oauth_client_id_1"

      assert actions2.requested_auth_configs["call_2"].raw_credential.client_id ==
               "oauth_client_id_2"
    end

    test "merged event actions contain both auth configs" do
      # Simulate merging auth configs from two tool executions into one event
      auth_config1 = make_auth_config("oauth_client_id_1", "oauth_client_secret1")
      auth_config2 = make_auth_config("oauth_client_id_2", "oauth_client_secret2")

      combined = %EventActions{
        requested_auth_configs: %{
          "call_1" => auth_config1,
          "call_2" => auth_config2
        }
      }

      configs = Map.values(combined.requested_auth_configs)
      assert length(configs) == 2

      client_ids = Enum.map(configs, & &1.raw_credential.client_id) |> Enum.sort()
      assert client_ids == ["oauth_client_id_1", "oauth_client_id_2"]
    end

    test "request_credential fails without function_call_id" do
      tc = ToolContext.new(make_ctx(), nil, %{name: "test"})
      auth_config = make_auth_config("client", "secret")
      assert {:error, :no_function_call_id} = ToolContext.request_credential(tc, auth_config)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: auth credential key generation
  # ---------------------------------------------------------------------------

  describe "auth config credential key" do
    test "same config produces same key" do
      config1 = make_auth_config("client_1", "secret_1")
      config2 = make_auth_config("client_1", "secret_1")

      assert Config.credential_key(config1) == Config.credential_key(config2)
    end

    test "different configs produce different keys" do
      config1 = make_auth_config("client_1", "secret_1")
      config2 = make_auth_config("client_2", "secret_2")

      refute Config.credential_key(config1) == Config.credential_key(config2)
    end

    test "explicit key overrides auto-generated" do
      config = make_auth_config("client_1", "secret_1", credential_key: "my_explicit_key")
      assert Config.credential_key(config) == "my_explicit_key"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: preprocessor processes auth responses (mirrors test_function_get_auth_response)
  # ---------------------------------------------------------------------------

  describe "preprocessor — auth response round-trip" do
    test "processes user auth response and identifies tools to resume" do
      auth_config = make_auth_config("client_1", "secret_1")
      auth_response = make_auth_response("client_1", "secret_1", "token1")

      # Event 1: model called the EUC function (adk_request_credential)
      euc_event =
        euc_function_call_event([
          {"euc_fc_1", "original_call_1", auth_config}
        ])

      # Event 2: user responded with the credential
      user_event =
        user_auth_response_event([
          {"euc_fc_1", auth_response}
        ])

      events = [euc_event, user_event]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "original_call_1")
    end

    test "processes multiple auth responses — all tools resumed" do
      auth_config1 = make_auth_config("client_1", "secret_1")
      auth_config2 = make_auth_config("client_2", "secret_2")
      auth_response1 = make_auth_response("client_1", "secret_1", "token1")
      auth_response2 = make_auth_response("client_2", "secret_2", "token2")

      euc_event =
        euc_function_call_event([
          {"euc_fc_1", "original_call_1", auth_config1},
          {"euc_fc_2", "original_call_2", auth_config2}
        ])

      user_event =
        user_auth_response_event([
          {"euc_fc_1", auth_response1},
          {"euc_fc_2", auth_response2}
        ])

      events = [euc_event, user_event]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "original_call_1")
      assert MapSet.member?(tool_ids, "original_call_2")
      assert MapSet.size(tool_ids) == 2
    end

    test "partial auth response — only responded tool is resumed" do
      # Mirrors test_function_get_auth_response_partial:
      # User provides auth for tool 1 but not tool 2
      auth_config1 = make_auth_config("client_1", "secret_1")
      auth_config2 = make_auth_config("client_2", "secret_2")
      auth_response1 = make_auth_response("client_1", "secret_1", "token1")

      euc_event =
        euc_function_call_event([
          {"euc_fc_1", "original_call_1", auth_config1},
          {"euc_fc_2", "original_call_2", auth_config2}
        ])

      # User only responds to the first auth request
      user_event =
        user_auth_response_event([
          {"euc_fc_1", auth_response1}
        ])

      events = [euc_event, user_event]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "original_call_1")
      # Tool 2 was NOT responded to, so it should NOT be in the resume set
      refute MapSet.member?(tool_ids, "original_call_2")
    end

    test "second partial response completes the remaining tool" do
      # After partial response for tool 1, user then responds for tool 2
      auth_config2 = make_auth_config("client_2", "secret_2")
      auth_response2 = make_auth_response("client_2", "secret_2", "token2")

      euc_event =
        euc_function_call_event([
          {"euc_fc_2", "original_call_2", auth_config2}
        ])

      user_event =
        user_auth_response_event([
          {"euc_fc_2", auth_response2}
        ])

      events = [euc_event, user_event]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "original_call_2")
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: preprocessor ignores non-auth events
  # ---------------------------------------------------------------------------

  describe "preprocessor — non-auth scenarios" do
    test "returns :noop when user event has no function responses" do
      user_event =
        Event.new(%{
          author: "user",
          content: %{"parts" => [%{"text" => "hello"}]}
        })

      assert :noop = Preprocessor.process([user_event], mock_llm_agent())
    end

    test "returns :noop when last event is not from user" do
      agent_event =
        Event.new(%{
          author: "model",
          content: %{"parts" => [%{"text" => "response"}]}
        })

      assert :noop = Preprocessor.process([agent_event], mock_llm_agent())
    end

    test "returns :noop for non-LLM agents" do
      auth_config = make_auth_config("client_1", "secret_1")

      user_event =
        user_auth_response_event([
          {"euc_fc_1", auth_config}
        ])

      non_llm_agent = %{__struct__: MyApp.CustomAgent, name: "custom"}
      assert :noop = Preprocessor.process([user_event], non_llm_agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: ToolsetAuth builds auth request events
  # ---------------------------------------------------------------------------

  describe "ToolsetAuth.build_auth_request_event" do
    test "builds event with adk_request_credential function calls" do
      ctx = make_ctx()
      ctx = %{ctx | agent: mock_llm_agent()}

      auth_config = make_auth_config("client_1", "secret_1")

      event =
        ADK.Auth.ToolsetAuth.build_auth_request_event(ctx, %{
          "fc_id_1" => auth_config
        })

      assert event.author == "root_agent"
      parts = event.content["parts"]
      assert length(parts) == 1

      fc = hd(parts)["function_call"]
      assert fc["name"] == @request_euc
      assert fc["id"] == "fc_id_1"
      assert fc["args"]["functionCallId"] == "fc_id_1"
    end

    test "builds event with multiple auth requests" do
      ctx = %{make_ctx() | agent: mock_llm_agent()}

      config1 = make_auth_config("client_1", "secret_1")
      config2 = make_auth_config("client_2", "secret_2")

      event =
        ADK.Auth.ToolsetAuth.build_auth_request_event(ctx, %{
          "fc_id_1" => config1,
          "fc_id_2" => config2
        })

      parts = event.content["parts"]
      assert length(parts) == 2

      fc_names =
        Enum.map(parts, fn p -> p["function_call"]["name"] end)
        |> Enum.uniq()

      assert fc_names == [@request_euc]

      fc_ids =
        Enum.map(parts, fn p -> p["function_call"]["id"] end)
        |> Enum.sort()

      assert fc_ids == ["fc_id_1", "fc_id_2"]
    end

    test "sets long_running_tool_ids in custom_metadata" do
      ctx = %{make_ctx() | agent: mock_llm_agent()}
      config = make_auth_config("client_1", "secret_1")

      event =
        ADK.Auth.ToolsetAuth.build_auth_request_event(ctx, %{
          "fc_id_1" => config,
          "fc_id_2" => config
        })

      ids = event.custom_metadata[:long_running_tool_ids] |> Enum.sort()
      assert ids == ["fc_id_1", "fc_id_2"]
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: full EUC data flow — request_credential → event → preprocessor
  # ---------------------------------------------------------------------------

  describe "full EUC data flow" do
    test "request_credential → build EUC event → preprocessor resume" do
      # Step 1: Tool requests a credential
      tc = make_tool_ctx("original_tool_call", "my_api_tool")
      auth_config = make_auth_config("client_1", "secret_1")

      assert {:ok, tc2} = ToolContext.request_credential(tc, auth_config)
      actions = ToolContext.actions(tc2)
      assert map_size(actions.requested_auth_configs) == 1

      # Step 2: Build EUC function call event (what the runner would emit)
      {call_id, config} = Enum.at(actions.requested_auth_configs, 0)
      assert call_id == "original_tool_call"

      ctx = %{make_ctx() | agent: mock_llm_agent()}

      # Build a real EUC event (demonstrating ToolsetAuth integration)
      _euc_event =
        ADK.Auth.ToolsetAuth.build_auth_request_event(ctx, %{
          "euc_for_#{call_id}" => config
        })

      # Manually build the matching system event for the preprocessor
      euc_system_event =
        euc_function_call_event([
          {"euc_for_original_tool_call", "original_tool_call", config}
        ])

      # Step 3: User provides the credential
      auth_response = make_auth_response("client_1", "secret_1", "my_access_token")

      user_response =
        user_auth_response_event([
          {"euc_for_original_tool_call", auth_response}
        ])

      # Step 4: Preprocessor identifies tool to resume
      events = [euc_system_event, user_response]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "original_tool_call")
    end

    test "multiple tools request credentials → all resumed after responses" do
      auth_config1 = make_auth_config("client_1", "secret_1")
      auth_config2 = make_auth_config("client_2", "secret_2")

      # Two tools request credentials
      tc1 = make_tool_ctx("tool_call_1", "api1")
      assert {:ok, _tc1} = ToolContext.request_credential(tc1, auth_config1)

      tc2 = make_tool_ctx("tool_call_2", "api2")
      assert {:ok, _tc2} = ToolContext.request_credential(tc2, auth_config2)

      # Build preprocessor input
      euc_event =
        euc_function_call_event([
          {"euc_1", "tool_call_1", auth_config1},
          {"euc_2", "tool_call_2", auth_config2}
        ])

      auth_response1 = make_auth_response("client_1", "secret_1", "token1")
      auth_response2 = make_auth_response("client_2", "secret_2", "token2")

      user_event =
        user_auth_response_event([
          {"euc_1", auth_response1},
          {"euc_2", auth_response2}
        ])

      events = [euc_event, user_event]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.size(tool_ids) == 2
      assert MapSet.member?(tool_ids, "tool_call_1")
      assert MapSet.member?(tool_ids, "tool_call_2")
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: credential storage integration
  # ---------------------------------------------------------------------------

  describe "credential storage through EUC flow" do
    setup do
      store_name = :"Agent_#{System.unique_integer([:positive])}"
      {:ok, store} = ADK.Auth.InMemoryStore.start_link(name: store_name)
      %{store: store, store_name: store_name}
    end

    test "preprocessor stores exchanged credential from auth response", %{store: store, store_name: store_name} do
      auth_config = make_auth_config("client_1", "secret_1", credential_key: "my_api_cred")

      auth_response =
        make_auth_response("client_1", "secret_1", "access_token_123",
          credential_key: "my_api_cred"
        )

      euc_event =
        euc_function_call_event([
          {"euc_fc_1", "tool_call_1", auth_config}
        ])

      user_event =
        user_auth_response_event([
          {"euc_fc_1", auth_response}
        ])

      events = [euc_event, user_event]

      # Create store wrapper module
      wrapper = create_store_wrapper(store_name)

      assert {:resume, _} =
               Preprocessor.process(events, mock_llm_agent(), credential_service: wrapper)

      # Verify the credential was stored
      assert {:ok, stored} = ADK.Auth.InMemoryStore.get("my_api_cred", server: store)
      assert stored.access_token == "access_token_123"
      assert stored.client_id == "client_1"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: EUC function call name constant
  # ---------------------------------------------------------------------------

  describe "EUC constants" do
    test "request_euc_function_call_name matches expected value" do
      assert @request_euc == "adk_request_credential"
    end

    test "toolset_auth_prefix is excluded from resume" do
      prefix = Preprocessor.toolset_auth_prefix()
      assert prefix == "_adk_toolset_auth_"

      auth_config = make_auth_config("client_1", "secret_1")

      # Toolset auth entries should NOT produce resume targets
      euc_event =
        euc_function_call_event([
          {"euc_fc_1", "#{prefix}some_toolset", auth_config}
        ])

      user_event =
        user_auth_response_event([
          {"euc_fc_1", make_auth_response("client_1", "secret_1", "token")}
        ])

      events = [euc_event, user_event]
      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_store_wrapper(store_name) do
    mod_name = :"ADK.Test.EucStore_#{System.unique_integer([:positive])}"

    Module.create(
      mod_name,
      quote do
        @behaviour ADK.Auth.CredentialStore
        @store_name unquote(store_name)

        @impl true
        def get(name, _opts), do: ADK.Auth.InMemoryStore.get(name, server: @store_name)

        @impl true
        def put(name, cred, _opts), do: ADK.Auth.InMemoryStore.put(name, cred, server: @store_name)

        @impl true
        def delete(name, _opts), do: ADK.Auth.InMemoryStore.delete(name, server: @store_name)
      end,
      Macro.Env.location(__ENV__)
    )

    mod_name
  end
end
