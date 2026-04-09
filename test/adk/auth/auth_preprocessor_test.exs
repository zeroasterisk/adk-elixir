defmodule ADK.Auth.PreprocessorTest do
  @moduledoc """
  Parity tests for Python ADK's `test_auth_preprocessor.py`.

  Tests the `ADK.Auth.Preprocessor` module which handles auth credential
  responses from session events before LLM requests. Mirrors the Python
  `_AuthLlmRequestProcessor` test patterns.
  """
  use ExUnit.Case, async: true

  alias ADK.Auth.Preprocessor
  alias ADK.Event

  @request_euc "adk_request_credential"

  # ---------------------------------------------------------------------------
  # Helpers — event builders
  # ---------------------------------------------------------------------------

  defp user_event_with_auth_response(auth_config, opts \\ []) do
    id = Keyword.get(opts, :id, "auth_response_id")

    Event.new(%{
      author: "user",
      content: %{
        "parts" => [
          %{
            "function_response" => %{
              "name" => @request_euc,
              "id" => id,
              "response" => auth_config
            }
          }
        ]
      }
    })
  end

  defp user_event_without_auth_response do
    Event.new(%{
      author: "user",
      content: %{
        "parts" => [
          %{
            "function_response" => %{
              "name" => "some_other_function",
              "id" => "other_response_id"
            }
          }
        ]
      }
    })
  end

  defp user_event_no_responses do
    Event.new(%{
      author: "user",
      content: %{"parts" => [%{"text" => "hello"}]}
    })
  end

  defp agent_event do
    Event.new(%{
      author: "test_agent",
      content: %{"parts" => [%{"text" => "response"}]}
    })
  end

  defp event_no_content do
    Event.new(%{author: "user", content: nil})
  end

  defp system_event_with_auth_calls(calls) do
    parts =
      Enum.map(calls, fn {id, function_call_id, auth_config} ->
        %{
          "function_call" => %{
            "name" => @request_euc,
            "id" => id,
            "args" => %{
              "function_call_id" => function_call_id,
              "auth_config" => auth_config
            }
          }
        }
      end)

    Event.new(%{
      author: "system",
      content: %{"parts" => parts}
    })
  end

  defp original_function_call_event(call_ids) do
    parts =
      Enum.map(call_ids, fn id ->
        %{
          "function_call" => %{
            "name" => "some_tool",
            "id" => id,
            "args" => %{}
          }
        }
      end)

    Event.new(%{
      author: "model",
      content: %{"parts" => parts}
    })
  end

  defp mock_llm_agent do
    %ADK.Agent.LlmAgent{
      name: "test_agent",
      model: "gemini-2.0-flash",
      instruction: "test"
    }
  end

  defp mock_non_llm_agent do
    %{__struct__: MyApp.BaseAgent, name: "base"}
  end

  defp mock_auth_config do
    %ADK.Auth.Config{
      credential_type: :oauth2,
      scopes: ["read", "write"]
    }
  end

  # ---------------------------------------------------------------------------
  # Tests: non-LLM agent returns early
  # ---------------------------------------------------------------------------

  describe "non-LLM agent" do
    test "returns :noop for non-LLM agent" do
      events = [user_event_with_auth_response(mock_auth_config())]
      assert :noop = Preprocessor.process(events, mock_non_llm_agent())
    end

    test "returns :noop for nil agent" do
      events = [user_event_with_auth_response(mock_auth_config())]
      assert :noop = Preprocessor.process(events, nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: empty/missing events
  # ---------------------------------------------------------------------------

  describe "empty events" do
    test "returns :noop for empty events list" do
      assert :noop = Preprocessor.process([], mock_llm_agent())
    end
  end

  describe "no events with content" do
    test "returns :noop when all events have nil content" do
      events = [event_no_content()]
      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: last event not user-authored
  # ---------------------------------------------------------------------------

  describe "last event with content not user-authored" do
    test "returns :noop when last content event is agent-authored" do
      events = [event_no_content(), agent_event()]
      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end

    test "skips nil-content events and checks actual last content event" do
      events = [agent_event(), event_no_content()]
      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: user event with no/non-auth responses
  # ---------------------------------------------------------------------------

  describe "user event with no responses" do
    test "returns :noop for user event with text only" do
      events = [user_event_no_responses()]
      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end
  end

  describe "user event with non-auth responses" do
    test "returns :noop when responses are not adk_request_credential" do
      events = [user_event_without_auth_response()]
      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: successful auth processing
  # ---------------------------------------------------------------------------

  describe "processes auth response successfully" do
    test "returns :noop when no matching system function calls (no resume targets)" do
      auth_config = mock_auth_config()
      events = [user_event_with_auth_response(auth_config)]
      # No system event with matching function calls → no tools to resume
      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end

    test "identifies auth responses and collects resume targets" do
      auth_config = mock_auth_config()

      system =
        system_event_with_auth_calls([
          {"auth_response_id", "tool_id_1", auth_config}
        ])

      original = original_function_call_event(["tool_id_1"])
      user = user_event_with_auth_response(auth_config)

      events = [original, system, user]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "tool_id_1")
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: multiple auth responses
  # ---------------------------------------------------------------------------

  describe "processes multiple auth responses" do
    test "collects all tools to resume from multiple auth responses" do
      auth_config = mock_auth_config()

      # Two auth responses from user
      user_event =
        Event.new(%{
          author: "user",
          content: %{
            "parts" => [
              %{
                "function_response" => %{
                  "name" => @request_euc,
                  "id" => "auth_id_1",
                  "response" => auth_config
                }
              },
              %{
                "function_response" => %{
                  "name" => @request_euc,
                  "id" => "auth_id_2",
                  "response" => auth_config
                }
              }
            ]
          }
        })

      system =
        system_event_with_auth_calls([
          {"auth_id_1", "tool_id_1", auth_config},
          {"auth_id_2", "tool_id_2", auth_config}
        ])

      original = original_function_call_event(["tool_id_1", "tool_id_2"])

      events = [original, system, user_event]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "tool_id_1")
      assert MapSet.member?(tool_ids, "tool_id_2")
      assert MapSet.size(tool_ids) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: no matching system function calls
  # ---------------------------------------------------------------------------

  describe "no matching system function calls" do
    test "returns :noop when system call IDs don't match auth response IDs" do
      auth_config = mock_auth_config()

      # System event with different ID than the auth response
      non_matching_system =
        Event.new(%{
          author: "system",
          content: %{
            "parts" => [
              %{
                "function_call" => %{
                  "name" => @request_euc,
                  "id" => "different_id",
                  "args" => %{
                    "function_call_id" => "tool_id_1",
                    "auth_config" => auth_config
                  }
                }
              }
            ]
          }
        })

      user = user_event_with_auth_response(auth_config)
      events = [non_matching_system, user]

      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: missing original function calls
  # ---------------------------------------------------------------------------

  describe "handles missing original function calls" do
    test "still collects tools to resume even without original event" do
      auth_config = mock_auth_config()

      system =
        system_event_with_auth_calls([
          {"auth_response_id", "tool_id_1", auth_config}
        ])

      # Empty event (no function calls — the original calls are "missing")
      empty =
        Event.new(%{
          author: "model",
          content: %{"parts" => [%{"text" => "ok"}]}
        })

      user = user_event_with_auth_response(auth_config)
      events = [empty, system, user]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "tool_id_1")
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: toolset auth exclusion
  # ---------------------------------------------------------------------------

  describe "toolset auth exclusion" do
    test "excludes toolset auth entries from resume targets" do
      auth_config = mock_auth_config()
      toolset_prefix = Preprocessor.toolset_auth_prefix()

      system =
        system_event_with_auth_calls([
          {"auth_response_id", "#{toolset_prefix}some_tool", auth_config}
        ])

      user = user_event_with_auth_response(auth_config)
      events = [system, user]

      # Toolset auth should be excluded, resulting in noop
      assert :noop = Preprocessor.process(events, mock_llm_agent())
    end

    test "resumes non-toolset tools while excluding toolset auth" do
      auth_config = mock_auth_config()
      toolset_prefix = Preprocessor.toolset_auth_prefix()

      # Mix of toolset and regular auth
      user_event =
        Event.new(%{
          author: "user",
          content: %{
            "parts" => [
              %{
                "function_response" => %{
                  "name" => @request_euc,
                  "id" => "auth_id_1",
                  "response" => auth_config
                }
              },
              %{
                "function_response" => %{
                  "name" => @request_euc,
                  "id" => "auth_id_2",
                  "response" => auth_config
                }
              }
            ]
          }
        })

      system =
        system_event_with_auth_calls([
          {"auth_id_1", "real_tool_id", auth_config},
          {"auth_id_2", "#{toolset_prefix}listing_tool", auth_config}
        ])

      events = [system, user_event]

      assert {:resume, tool_ids} = Preprocessor.process(events, mock_llm_agent())
      assert MapSet.member?(tool_ids, "real_tool_id")
      refute MapSet.member?(tool_ids, "#{toolset_prefix}listing_tool")
      assert MapSet.size(tool_ids) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: isinstance check / agent type validation
  # ---------------------------------------------------------------------------

  describe "agent type validation" do
    test "returns :noop for plain map (not an LlmAgent struct)" do
      events = [user_event_with_auth_response(mock_auth_config())]
      assert :noop = Preprocessor.process(events, %{name: "not_an_agent"})
    end

    test "returns :noop for atom" do
      events = [user_event_with_auth_response(mock_auth_config())]
      assert :noop = Preprocessor.process(events, :not_an_agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: credential storage with service
  # ---------------------------------------------------------------------------

  describe "credential storage" do
    setup do
      store_name = :"Agent_#{System.unique_integer([:positive])}"
      {:ok, store} = ADK.Auth.InMemoryStore.start_link(name: store_name)
      %{store: store, store_name: store_name}
    end

    test "stores exchanged credential from auth response", %{store: store, store_name: store_name} do
      cred =
        ADK.Auth.Credential.oauth2("access-token-123",
          client_id: "client1",
          client_secret: "secret1"
        )

      auth_config = %ADK.Auth.Config{
        credential_type: :oauth2,
        credential_key: "my_cred_key",
        exchanged_credential: cred
      }

      system =
        system_event_with_auth_calls([
          {"auth_response_id", "tool_id_1", auth_config}
        ])

      user = user_event_with_auth_response(auth_config)
      events = [system, user]

      # Create a wrapper that delegates to InMemoryStore
      wrapper = create_store_wrapper(store_name)

      assert {:resume, _} =
               Preprocessor.process(events, mock_llm_agent(), credential_service: wrapper)

      # Verify credential was stored
      assert {:ok, stored} = ADK.Auth.InMemoryStore.get("my_cred_key", server: store)
      assert stored.access_token == "access-token-123"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: request_euc_function_call_name and toolset_auth_prefix
  # ---------------------------------------------------------------------------

  describe "constants" do
    test "request_euc_function_call_name returns expected value" do
      assert Preprocessor.request_euc_function_call_name() == "adk_request_credential"
    end

    test "toolset_auth_prefix returns expected value" do
      assert Preprocessor.toolset_auth_prefix() == "_adk_toolset_auth_"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_store_wrapper(store_name) do
    mod_name = :"ADK.Test.PreprocessorStore_#{System.unique_integer([:positive])}"

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
