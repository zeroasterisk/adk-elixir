defmodule ADK.LLM.GoogleLLMParityTest do
  @moduledoc """
  Parity tests for the Elixir Google LLM (Gemini) backend, ported from
  Python's tests/unittests/models/test_google_llm.py.

  Covers:
  - Request body construction (generate_config, system instruction, tools)
  - Multi-turn conversation history
  - Function response parts in conversation
  - Mixed text + function call responses
  - Error handling (401, 429, 500, missing auth)
  - Bearer token authentication
  - Safety settings in request
  - Usage metadata in response
  - Empty / malformed response handling
  - Default model fallback
  """

  use ExUnit.Case, async: false

  alias ADK.LLM.Gemini

  setup do
    original_gemini_key = System.get_env("GEMINI_API_KEY")
    Application.put_env(:adk, :gemini_api_key, "test-key")
    Application.put_env(:adk, :gemini_test_plug, true)

    on_exit(fn ->
      Application.delete_env(:adk, :gemini_api_key)
      Application.delete_env(:adk, :gemini_test_plug)
      Application.delete_env(:adk, :gemini_bearer_token)
      System.delete_env("GEMINI_BEARER_TOKEN")

      # Restore GEMINI_API_KEY env var if it was set before the test
      if original_gemini_key, do: System.put_env("GEMINI_API_KEY", original_gemini_key)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stub(status, body) do
    Req.Test.stub(Gemini, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp ok_response(text \\ "OK") do
    %{
      "candidates" => [
        %{
          "content" => %{
            "role" => "model",
            "parts" => [%{"text" => text}]
          },
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 10,
        "candidatesTokenCount" => 5,
        "totalTokenCount" => 15
      }
    }
  end

  defp read_request_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  # ---------------------------------------------------------------------------
  # Request body — generate_config (temperature, topP, topK, maxOutputTokens)
  # ---------------------------------------------------------------------------

  describe "generate_config is serialised to generationConfig" do
    test "temperature is forwarded to API" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        assert get_in(decoded, ["generationConfig", "temperature"]) == 0.1
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 generate_config: %{temperature: 0.1}
               })
    end

    test "maxOutputTokens is mapped from max_output_tokens" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        assert get_in(decoded, ["generationConfig", "maxOutputTokens"]) == 512
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 generate_config: %{max_output_tokens: 512}
               })
    end

    test "multiple generation config params are all sent" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        gen = decoded["generationConfig"]
        assert gen["temperature"] == 0.7
        assert gen["topP"] == 0.9
        assert gen["maxOutputTokens"] == 256
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 generate_config: %{temperature: 0.7, top_p: 0.9, max_output_tokens: 256}
               })
    end

    test "empty generate_config does not send generationConfig key" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        refute Map.has_key?(decoded, "generationConfig")
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 generate_config: %{}
               })
    end

    test "nil generate_config does not send generationConfig key" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        refute Map.has_key?(decoded, "generationConfig")
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end

    test "stop_sequences are forwarded" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        assert get_in(decoded, ["generationConfig", "stopSequences"]) == ["END", "STOP"]
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 generate_config: %{stop_sequences: ["END", "STOP"]}
               })
    end

    test "response_mime_type is forwarded" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        assert get_in(decoded, ["generationConfig", "responseMimeType"]) == "application/json"
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 generate_config: %{response_mime_type: "application/json"}
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-turn conversation (mirrors _maybe_append_user_content behavior)
  # ---------------------------------------------------------------------------

  describe "multi-turn conversation history" do
    test "all turns are included in contents array" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        contents = decoded["contents"]
        assert length(contents) == 3
        assert Enum.at(contents, 0)["role"] == "user"
        assert Enum.at(contents, 1)["role"] == "model"
        assert Enum.at(contents, 2)["role"] == "user"
        Req.Test.json(conn, ok_response("follow-up"))
      end)

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [
                   %{role: :user, parts: [%{text: "Hello"}]},
                   %{role: :model, parts: [%{text: "Hi there!"}]},
                   %{role: :user, parts: [%{text: "How are you?"}]}
                 ]
               })

      assert [%{text: "follow-up"}] = resp.content.parts
    end

    test "function call followed by function response is preserved in history" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        contents = decoded["contents"]
        assert length(contents) == 4

        # Turn 3: model function call
        model_turn = Enum.at(contents, 2)
        assert model_turn["role"] == "model"
        [fc_part] = model_turn["parts"]
        assert fc_part["functionCall"]["name"] == "search"

        # Turn 4: tool response
        tool_turn = Enum.at(contents, 3)
        assert tool_turn["role"] == "tool"
        [fr_part] = tool_turn["parts"]
        assert fr_part["functionResponse"]["name"] == "search"

        Req.Test.json(conn, ok_response("Based on the search: answer"))
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [
                   %{role: :user, parts: [%{text: "Search for Elixir"}]},
                   %{role: :model, parts: [%{text: "Let me search."}]},
                   %{
                     role: :model,
                     parts: [%{function_call: %{name: "search", args: %{"query" => "Elixir"}}}]
                   },
                   %{
                     role: :tool,
                     parts: [
                       %{
                         function_response: %{
                           name: "search",
                           response: %{"result" => "Elixir is a functional language"}
                         }
                       }
                     ]
                   }
                 ]
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  describe "response parsing" do
    test "text response returns correct content" do
      stub(200, ok_response("Hello, how can I help you?"))

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "Hello"}]}]
               })

      assert resp.content.role == :model
      assert [%{text: "Hello, how can I help you?"}] = resp.content.parts
    end

    test "usage_metadata is included in response" do
      stub(200, ok_response())

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })

      assert resp.usage_metadata["promptTokenCount"] == 10
      assert resp.usage_metadata["candidatesTokenCount"] == 5
      assert resp.usage_metadata["totalTokenCount"] == 15
    end

    test "usage_metadata is nil when not in response" do
      stub(200, %{
        "candidates" => [
          %{"content" => %{"role" => "model", "parts" => [%{"text" => "hi"}]}}
        ]
      })

      assert {:ok, resp} = Gemini.generate("gemini-flash-latest", %{messages: []})
      assert is_nil(resp.usage_metadata)
    end

    test "function call in response is parsed correctly" do
      stub(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Paris"}}}
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "Weather in Paris?"}]}],
                 tools: [%{name: "get_weather", description: "Get weather"}]
               })

      assert [%{function_call: %{name: "get_weather", args: %{"city" => "Paris"}}}] =
               resp.content.parts
    end

    test "multiple parts in response (text + function_call) are all returned" do
      stub(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"text" => "Let me look that up."},
                %{"functionCall" => %{"name" => "lookup", "args" => %{"q" => "Elixir"}}}
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "Tell me about Elixir"}]}],
                 tools: [%{name: "lookup", description: "Look something up"}]
               })

      assert length(resp.content.parts) == 2
      assert Enum.any?(resp.content.parts, &match?(%{text: _}, &1))
      assert Enum.any?(resp.content.parts, &match?(%{function_call: _}, &1))
    end

    test "malformed response with no candidates returns empty content" do
      stub(200, %{"usageMetadata" => %{"promptTokenCount" => 0}})

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })

      # Should gracefully return empty content
      assert resp.content.role == :model
      assert [%{text: ""}] = resp.content.parts
    end

    test "empty candidates list returns empty content" do
      stub(200, %{"candidates" => []})

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })

      assert resp.content.role == :model
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling — mirrors test_generate_content_async_resource_exhausted_error
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "returns :rate_limited on 429 (resource exhausted)" do
      stub(429, %{"error" => %{"message" => "Quota exceeded"}})
      assert {:error, :rate_limited} = Gemini.generate("gemini-flash-latest", %{messages: []})
    end

    test "returns :unauthorized on 401" do
      stub(401, %{"error" => %{"message" => "API key not valid"}})
      assert {:error, :unauthorized} = Gemini.generate("gemini-flash-latest", %{messages: []})
    end

    test "returns :api_error tuple on 500 with status and body" do
      stub(500, %{"error" => %{"message" => "Internal error"}})

      assert {:error, {:api_error, 500, body}} =
               Gemini.generate("gemini-flash-latest", %{messages: []})

      assert body["error"]["message"] == "Internal error"
    end

    test "returns :missing_api_key when no credentials configured" do
      Application.delete_env(:adk, :gemini_api_key)
      Application.delete_env(:adk, :gemini_bearer_token)
      System.delete_env("GEMINI_API_KEY")
      System.delete_env("GEMINI_BEARER_TOKEN")

      assert {:error, :missing_api_key} =
               Gemini.generate("gemini-flash-latest", %{messages: []})
    end

    test "returns :api_error on 403" do
      stub(403, %{"error" => %{"message" => "Permission denied"}})

      assert {:error, {:api_error, 403, _}} =
               Gemini.generate("gemini-flash-latest", %{messages: []})
    end
  end

  # ---------------------------------------------------------------------------
  # Authentication — bearer token (mirrors the Vertex AI backend auth path)
  # ---------------------------------------------------------------------------

  describe "bearer token authentication" do
    test "uses bearer token from application config when set" do
      Application.delete_env(:adk, :gemini_api_key)
      System.delete_env("GEMINI_API_KEY")
      Application.put_env(:adk, :gemini_bearer_token, "my-bearer-token")

      Req.Test.stub(Gemini, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        assert auth_header == ["Bearer my-bearer-token"]

        # No api key in query params
        query = conn.query_string || ""
        refute query =~ "key="

        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end

    test "api_key takes precedence over bearer token" do
      Application.put_env(:adk, :gemini_api_key, "api-key-123")
      Application.put_env(:adk, :gemini_bearer_token, "bearer-token-xyz")

      Req.Test.stub(Gemini, fn conn ->
        query = conn.query_string || ""
        assert query =~ "key=api-key-123"

        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        assert auth_header == []

        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Request structure — system instruction
  # ---------------------------------------------------------------------------

  describe "system instruction in request" do
    test "system instruction is serialised correctly" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)

        assert decoded["system_instruction"] == %{
                 "parts" => [%{"text" => "You are a helpful assistant"}]
               }

        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 instruction: "You are a helpful assistant",
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end

    test "no system instruction key when instruction is nil" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        refute Map.has_key?(decoded, "system_instruction")
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end

    test "no system instruction key when instruction is empty string" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        refute Map.has_key?(decoded, "system_instruction")
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 instruction: "",
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Tool declarations
  # ---------------------------------------------------------------------------

  describe "tool declarations in request" do
    test "function declarations are nested under tools array" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        [tool] = decoded["tools"]
        assert Map.has_key?(tool, "function_declarations")
        decls = tool["function_declarations"]
        assert length(decls) == 1
        assert hd(decls)["name"] == "my_tool"
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 tools: [%{name: "my_tool", description: "Does something"}]
               })
    end

    test "tool with parameters includes parameters in declaration" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        [tool] = decoded["tools"]
        [decl] = tool["function_declarations"]
        assert decl["parameters"]["type"] == "object"
        assert Map.has_key?(decl["parameters"]["properties"], "query")
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "search"}]}],
                 tools: [
                   %{
                     name: "search",
                     description: "Search",
                     parameters: %{
                       type: "object",
                       properties: %{query: %{type: "string"}},
                       required: ["query"]
                     }
                   }
                 ]
               })
    end

    test "empty tools list does not send tools key" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        refute Map.has_key?(decoded, "tools")
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 tools: []
               })
    end

    test "multiple function tools are combined into one function_declarations list" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        [tool] = decoded["tools"]
        decls = tool["function_declarations"]
        assert length(decls) == 3
        names = Enum.map(decls, & &1["name"])
        assert "search" in names
        assert "calculate" in names
        assert "translate" in names
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 tools: [
                   %{name: "search", description: "Search"},
                   %{name: "calculate", description: "Calculate"},
                   %{name: "translate", description: "Translate"}
                 ]
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Safety settings
  # ---------------------------------------------------------------------------

  describe "safety settings" do
    test "safety settings from generate_config are forwarded" do
      safety_settings = [
        %{"category" => "HARM_CATEGORY_HARASSMENT", "threshold" => "BLOCK_NONE"},
        %{"category" => "HARM_CATEGORY_HATE_SPEECH", "threshold" => "BLOCK_NONE"}
      ]

      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        assert decoded["safetySettings"] == safety_settings
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}],
                 generate_config: %{safety_settings: safety_settings}
               })
    end

    test "no safetySettings key when not provided" do
      Req.Test.stub(Gemini, fn conn ->
        {decoded, conn} = read_request_body(conn)
        refute Map.has_key?(decoded, "safetySettings")
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Default model (mirrors supported_models / fallback behaviour)
  # ---------------------------------------------------------------------------

  describe "default model fallback" do
    test "nil model uses gemini-flash-latest" do
      Req.Test.stub(Gemini, fn conn ->
        assert conn.request_path =~ "gemini-flash-latest"
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} = Gemini.generate(nil, %{messages: []})
    end

    test "empty string model uses gemini-flash-latest" do
      Req.Test.stub(Gemini, fn conn ->
        assert conn.request_path =~ "gemini-flash-latest"
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} = Gemini.generate("", %{messages: []})
    end

    test "explicit model name is used as-is" do
      Req.Test.stub(Gemini, fn conn ->
        assert conn.request_path =~ "gemini-2.0-flash"
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} = Gemini.generate("gemini-2.0-flash", %{messages: []})
    end
  end

  # ---------------------------------------------------------------------------
  # Code execution response parts (mirrors parse_response_part tests)
  # ---------------------------------------------------------------------------

  describe "code execution response parsing" do
    test "executable_code part is parsed" do
      stub(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"executableCode" => %{"language" => "PYTHON", "code" => "print(42)"}}
              ]
            }
          }
        ]
      })

      assert {:ok, resp} = Gemini.generate("gemini-flash-latest", %{messages: []})
      [part] = resp.content.parts
      assert part.executable_code.language == "PYTHON"
      assert part.executable_code.code == "print(42)"
    end

    test "code_execution_result part is parsed" do
      stub(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{
                  "codeExecutionResult" => %{
                    "outcome" => "OUTCOME_OK",
                    "output" => "42\n"
                  }
                }
              ]
            }
          }
        ]
      })

      assert {:ok, resp} = Gemini.generate("gemini-flash-latest", %{messages: []})
      [part] = resp.content.parts
      assert part.code_execution_result.outcome == "OUTCOME_OK"
      assert part.code_execution_result.output == "42\n"
    end

    test "code_execution_result without output defaults to empty string" do
      stub(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"codeExecutionResult" => %{"outcome" => "OUTCOME_FAILED"}}
              ]
            }
          }
        ]
      })

      assert {:ok, resp} = Gemini.generate("gemini-flash-latest", %{messages: []})
      [part] = resp.content.parts
      assert part.code_execution_result.outcome == "OUTCOME_FAILED"
      assert part.code_execution_result.output == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Request URL construction
  # ---------------------------------------------------------------------------

  describe "request URL construction" do
    test "model name is embedded in URL path" do
      Req.Test.stub(Gemini, fn conn ->
        assert conn.request_path =~ "gemini-1.5-flash"
        assert conn.request_path =~ "generateContent"
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-1.5-flash", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end

    test "api_key is sent as query parameter" do
      Req.Test.stub(Gemini, fn conn ->
        query = conn.query_string || ""
        assert query =~ "key=test-key"
        Req.Test.json(conn, ok_response())
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "hi"}]}]
               })
    end
  end
end
