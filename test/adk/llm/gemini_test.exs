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

  describe "generate/2 - toolConfig" do
    test "sends toolConfig with AUTO mode when tools are present" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["tools"] != nil
        assert decoded["toolConfig"] == %{
                 "functionCallingConfig" => %{"mode" => "AUTO"}
               }

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 tools: [%{name: "search", description: "Search"}]
               })
    end

    test "does not send toolConfig when no tools are present" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute Map.has_key?(decoded, "toolConfig")

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}]
               })
    end

    test "allows custom toolConfig override" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["toolConfig"] == %{
                 "functionCallingConfig" => %{"mode" => "ANY"}
               }

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 tools: [%{name: "search", description: "Search"}],
                 tool_config: %{functionCallingConfig: %{mode: "ANY"}}
               })
    end
  end

  describe "generate/2 - error handling" do
    test "returns :unauthorized on 401" do
      stub_gemini(401, %{"error" => %{"message" => "Invalid API key"}})
      assert {:error, :unauthorized} = Gemini.generate("gemini-flash-latest", %{messages: []})
    end

    test "returns :retry_after on 429 (retry handled by ADK.LLM.generate)" do
      stub_gemini(429, %{"error" => %{"message" => "Rate limited"}})

      assert {:retry_after, _ms, :rate_limited} =
               Gemini.generate("gemini-flash-latest", %{messages: []})
    end

    test "returns :api_error on 500" do
      stub_gemini(500, %{"error" => %{"message" => "Internal error"}})

      assert {:error, {:api_error, 500, _}} =
               Gemini.generate("gemini-flash-latest", %{messages: []})
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

  describe "generate/2 - thoughtSignature round-trip" do
    test "parses thoughtSignature from text parts" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"text" => "Let me think...", "thoughtSignature" => "abc123"}
              ]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      assert [%{text: "Let me think...", thought_signature: "abc123"}] = resp.content.parts
    end

    test "parses thoughtSignature from function call parts" do
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
                  },
                  "thoughtSignature" => "sig456"
                }
              ]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "Weather?"}]}],
                 tools: [%{name: "get_weather", description: "Get weather"}]
               })

      assert [%{function_call: %{name: "get_weather"}, thought_signature: "sig456"}] =
               resp.content.parts
    end

    test "text parts without thoughtSignature have no thought_signature key" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [%{"text" => "No signature here"}]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      assert [%{text: "No signature here"} = part] = resp.content.parts
      refute Map.has_key?(part, :thought_signature)
    end

    test "formats thought_signature back to camelCase thoughtSignature in request" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Check that the assistant message's text part has thoughtSignature (camelCase)
        assistant_content =
          Enum.find(decoded["contents"], &(&1["role"] == "model"))

        assert assistant_content
        text_part = hd(assistant_content["parts"])
        assert text_part["thoughtSignature"] == "roundtrip_sig"
        assert text_part["text"] == "thinking..."

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "done"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [
                   %{role: :user, parts: [%{text: "Hi"}]},
                   %{role: :model, parts: [%{text: "thinking...", thought_signature: "roundtrip_sig"}]},
                   %{role: :user, parts: [%{text: "Continue"}]}
                 ]
               })
    end

    test "formats thought_signature on function_call parts back to camelCase" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assistant_content =
          Enum.find(decoded["contents"], &(&1["role"] == "model"))

        assert assistant_content
        fc_part = hd(assistant_content["parts"])
        assert fc_part["thoughtSignature"] == "fc_sig"
        assert fc_part["functionCall"]["name"] == "search"

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [
                   %{role: :user, parts: [%{text: "Search"}]},
                   %{
                     role: :model,
                     parts: [
                       %{
                         function_call: %{name: "search", args: %{"q" => "test"}},
                         thought_signature: "fc_sig"
                       }
                     ]
                   },
                   %{
                     role: :user,
                     parts: [%{function_response: %{name: "search", response: %{"r" => "ok"}}}]
                   }
                 ]
               })
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

  describe "generate/2 - generationConfig fields from Python SDK" do
    test "sends presencePenalty, frequencyPenalty, seed" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        gc = decoded["generationConfig"]

        assert gc["presencePenalty"] == 0.5
        assert gc["frequencyPenalty"] == 0.3
        assert gc["seed"] == 42

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 generate_config: %{presence_penalty: 0.5, frequency_penalty: 0.3, seed: 42}
               })
    end

    test "sends responseLogprobs, logprobs, responseModalities" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        gc = decoded["generationConfig"]

        assert gc["responseLogprobs"] == true
        assert gc["logprobs"] == 5
        assert gc["responseModalities"] == ["TEXT", "IMAGE"]

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 generate_config: %{
                   response_logprobs: true,
                   logprobs: 5,
                   response_modalities: ["TEXT", "IMAGE"]
                 }
               })
    end

    test "sends thinkingConfig in generationConfig" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        gc = decoded["generationConfig"]

        assert gc["thinkingConfig"] == %{"thinkingBudget" => 1024}

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 generate_config: %{thinking_config: %{"thinkingBudget" => 1024}}
               })
    end

    test "sends responseJsonSchema in generationConfig" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        gc = decoded["generationConfig"]

        assert gc["responseJsonSchema"] == %{"type" => "object"}

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 generate_config: %{response_json_schema: %{"type" => "object"}}
               })
    end
  end

  describe "generate/2 - thought parts (thinking models)" do
    test "parses thought: true on text parts" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"text" => "Let me reason...", "thought" => true},
                %{"text" => "The answer is 42."}
              ]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "What is 6*7?"}]}]
               })

      [thought_part, answer_part] = resp.content.parts
      assert thought_part.thought == true
      assert thought_part.text == "Let me reason..."
      refute Map.has_key?(answer_part, :thought)
      assert answer_part.text == "The answer is 42."
    end

    test "thought and thoughtSignature can coexist" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"text" => "thinking...", "thought" => true, "thoughtSignature" => "sig1"}
              ]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      [part] = resp.content.parts
      assert part.thought == true
      assert part.thought_signature == "sig1"
    end
  end

  describe "generate/2 - response metadata" do
    test "parses promptFeedback from response" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [%{"text" => "ok"}]
            }
          }
        ],
        "promptFeedback" => %{"blockReason" => "SAFETY"}
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}]
               })

      assert resp.prompt_feedback == %{"blockReason" => "SAFETY"}
    end

    test "parses modelVersion from response" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [%{"text" => "ok"}]
            }
          }
        ],
        "modelVersion" => "gemini-2.5-flash-001"
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}]
               })

      assert resp.model_version == "gemini-2.5-flash-001"
    end

    test "omits prompt_feedback and model_version when absent" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [%{"text" => "ok"}]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}]
               })

      refute Map.has_key?(resp, :prompt_feedback)
      refute Map.has_key?(resp, :model_version)
    end
  end

  describe "generate/2 - FunctionCall.id" do
    test "parses id from function call response" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "search",
                    "args" => %{"q" => "test"},
                    "id" => "call_123"
                  }
                }
              ]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "search"}]}],
                 tools: [%{name: "search", description: "Search"}]
               })

      [%{function_call: fc}] = resp.content.parts
      assert fc.name == "search"
      assert fc.id == "call_123"
    end

    test "omits id from function call when absent" do
      stub_gemini(200, %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "search",
                    "args" => %{"q" => "test"}
                  }
                }
              ]
            }
          }
        ]
      })

      assert {:ok, resp} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [%{role: :user, parts: [%{text: "search"}]}],
                 tools: [%{name: "search", description: "Search"}]
               })

      [%{function_call: fc}] = resp.content.parts
      refute Map.has_key?(fc, :id)
    end

    test "formats id back into functionCall request" do
      Req.Test.stub(Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        model_content = Enum.find(decoded["contents"], &(&1["role"] == "model"))
        fc_part = hd(model_content["parts"])
        assert fc_part["functionCall"]["id"] == "call_456"
        assert fc_part["functionCall"]["name"] == "search"

        Req.Test.json(conn, %{
          "candidates" => [
            %{"content" => %{"role" => "model", "parts" => [%{"text" => "done"}]}}
          ]
        })
      end)

      assert {:ok, _} =
               Gemini.generate("gemini-flash-latest", %{
                 messages: [
                   %{role: :user, parts: [%{text: "search"}]},
                   %{
                     role: :model,
                     parts: [
                       %{function_call: %{name: "search", args: %{"q" => "test"}, id: "call_456"}}
                     ]
                   },
                   %{
                     role: :user,
                     parts: [
                       %{function_response: %{name: "search", response: %{"r" => "ok"}}}
                     ]
                   }
                 ]
               })
    end
  end
end
