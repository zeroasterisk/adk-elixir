defmodule ADK.LLM.GeminiTest do
  use ExUnit.Case, async: false

  alias ADK.LLM.Gemini

  setup do
    Application.put_env(:adk, :gemini_api_key, "test-key")
    Application.put_env(:adk, :gemini_test_plug, true)

    on_exit(fn ->
      Application.delete_env(:adk, :gemini_api_key)
      Application.delete_env(:adk, :gemini_test_plug)
    end)

    :ok
  end

  defp stub_gemini(status, body) do
    Req.Test.stub(Gemini, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  describe "generate/2 - text response" do
    test "returns parsed text response" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [%{"text" => "Hello! How can I help?"}]
            }
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 8
        }
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 instruction: "Be helpful.",
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      assert resp.content.role == :model
      assert [%{text: "Hello! How can I help?"}] = resp.content.parts
      assert resp.usage_metadata["promptTokenCount"] == 10
    end
  end

  describe "generate/2 - function call response" do
    test "returns parsed function call" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "get_weather",
                    "args" => %{"city" => "London"}
                  }
                }
              ]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "Weather in London?"}]}],
                 tools: [
                   %{
                     name: "get_weather",
                     description: "Get weather",
                     parameters: %{
                       type: "object",
                       properties: %{city: %{type: "string"}}
                     }
                   }
                 ]
               })

      assert [%{function_call: %{name: "get_weather", args: %{"city" => "London"}}}] =
               resp.content.parts
    end
  end

  describe "generate/2 - system instruction" do
    test "sends system instruction in request body" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["system_instruction"] == %{
                 "parts" => [%{"text" => "You are a pirate."}]
               }

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "Arrr!"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 instruction: "You are a pirate.",
                 messages: [%{role: :user, parts: [%{text: "Hello"}]}]
               })
    end
  end

  describe "generate/2 - tool declarations" do
    test "sends tool declarations in request body" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [%{"function_declarations" => decls}] = decoded["tools"]
        assert length(decls) == 2
        assert Enum.any?(decls, &(&1["name"] == "search"))
        assert Enum.any?(decls, &(&1["name"] == "calculate"))

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 tools: [
                   %{name: "search", description: "Search the web"},
                   %{name: "calculate", description: "Do math", parameters: %{type: "object"}}
                 ]
               })
    end
  end

  describe "generate/2 - error handling" do
    test "returns :unauthorized on 401" do
      stub_gemini(401, %{"error" => %{"message" => "Invalid API key"}})
      assert {:error, :unauthorized} = Gemini.generate("gemini-flash-latest", %{messages: []})
    end

    test "returns :rate_limited on 429" do
      stub_gemini(429, %{"error" => %{"message" => "Rate limited"}})
      assert {:error, :rate_limited} = Gemini.generate("gemini-flash-latest", %{messages: []})
    end

    test "returns :api_error on 500" do
      stub_gemini(500, %{"error" => %{"message" => "Internal error"}})
      assert {:error, {:api_error, 500, _}} = Gemini.generate("gemini-flash-latest", %{messages: []})
    end

    test "returns :missing_api_key when no key configured" do
      Application.delete_env(:adk, :gemini_api_key)
      System.delete_env("GEMINI_API_KEY")

      assert {:error, :missing_api_key} =
               Gemini.generate("gemini-flash-latest", %{messages: []})
    end
  end

  describe "generate/2 - built-in tools" do
    test "google_search tool is sent as native capability, not function_declarations" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Should NOT have function_declarations
        tools = decoded["tools"] || []
        refute Enum.any?(tools, &Map.has_key?(&1, "functionDeclarations"))

        # Should have google_search capability
        assert Enum.any?(tools, &Map.has_key?(&1, "google_search"))

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "results"}]}}
          ]
        })
      end)

      google_search = ADK.Tool.GoogleSearch.new()
      decl = ADK.Tool.declaration(google_search)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "search for elixir"}]}],
                 tools: [decl]
               })
    end

    test "code_execution tool is sent as native capability" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        tools = decoded["tools"] || []
        assert Enum.any?(tools, &Map.has_key?(&1, "code_execution"))

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "done"}]}}
          ]
        })
      end)

      code_exec = ADK.Tool.BuiltInCodeExecution.new()
      decl = ADK.Tool.declaration(code_exec)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "run some python"}]}],
                 tools: [decl]
               })
    end

    test "code execution response parts are parsed correctly" do
      Req.Test.stub(Gemini, fn conn ->
        Req.Test.json(conn, %{
          "candidates" => [
            %{
              "content" => %{
                "role" => "model",
                "parts" => [
                  %{"executableCode" => %{"language" => "PYTHON", "code" => "print(42)"}},
                  %{"codeExecutionResult" => %{"outcome" => "OUTCOME_OK", "output" => "42\n"}}
                ]
              }
            }
          ]
        })
      end)

      code_exec = ADK.Tool.BuiltInCodeExecution.new()
      decl = ADK.Tool.declaration(code_exec)

      assert {:ok, response} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "compute 6*7"}]}],
                 tools: [decl]
               })

      parts = response.content.parts
      assert Enum.any?(parts, &match?(%{executable_code: _}, &1))
      assert Enum.any?(parts, &match?(%{code_execution_result: _}, &1))
    end
  end

  describe "generate/2 - default model" do
    test "uses default model when nil" do
      Req.Test.stub(Gemini, fn conn ->
        assert conn.request_path =~ "gemini-flash-latest"

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "hi"}]}}
          ]
        })
      end)

      assert {:ok, _} = Gemini.generate(nil, %{messages: []})
    end
  end
end
