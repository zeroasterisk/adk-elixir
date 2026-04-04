defmodule ADK.LLM.AnthropicTest do
  use ExUnit.Case, async: false

  alias ADK.LLM.Anthropic

  setup do
    Application.put_env(:adk, :anthropic_api_key, "sk-ant-test-key")
    Application.put_env(:adk, :anthropic_test_plug, true)

    on_exit(fn ->
      Application.delete_env(:adk, :anthropic_api_key)
      Application.delete_env(:adk, :anthropic_test_plug)
    end)

    :ok
  end

  defp stub_anthropic(status, body) do
    Req.Test.stub(Anthropic, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  describe "generate/2 - text response" do
    test "returns parsed text response" do
      stub_anthropic(200, %{
        "content" => [%{"type" => "text", "text" => "Hello! How can I help?"}],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 8}
      })

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 instruction: "Be helpful.",
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      assert resp.content.role == :model
      assert [%{text: "Hello! How can I help?"}] = resp.content.parts
      assert resp.usage_metadata["input_tokens"] == 10
    end
  end

  describe "generate/2 - tool_use response" do
    test "returns parsed tool_use blocks" do
      stub_anthropic(200, %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_abc123",
            "name" => "get_weather",
            "input" => %{"city" => "London"}
          }
        ]
      })

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [%{role: :user, parts: [%{text: "Weather in London?"}]}],
                 tools: [
                   %{
                     name: "get_weather",
                     description: "Get weather",
                     parameters: %{type: "object", properties: %{city: %{type: "string"}}}
                   }
                 ]
               })

      assert [%{function_call: fc}] = resp.content.parts
      assert fc.name == "get_weather"
      assert fc.args == %{"city" => "London"}
      assert fc.id == "toolu_abc123"
    end
  end

  describe "generate/2 - system instruction" do
    test "sends system as top-level param, not in messages" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["system"] == "You are a pirate."
        # System should NOT appear in messages
        refute Enum.any?(decoded["messages"], &(&1["role"] == "system"))

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "Arrr!"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 instruction: "You are a pirate.",
                 messages: [%{role: :user, parts: [%{text: "Hello"}]}]
               })
    end
  end

  describe "generate/2 - tool declarations" do
    test "sends tools in Anthropic format with input_schema" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        tools = decoded["tools"]
        assert length(tools) == 2
        assert Enum.all?(tools, &Map.has_key?(&1, "input_schema"))
        assert Enum.any?(tools, &(&1["name"] == "search"))

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 tools: [
                   %{name: "search", description: "Search the web"},
                   %{name: "calculate", description: "Do math", parameters: %{type: "object"}}
                 ]
               })
    end
  end

  describe "generate/2 - message formatting" do
    test "maps ADK roles to Anthropic roles" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        roles = Enum.map(decoded["messages"], & &1["role"])
        assert roles == ["user", "assistant", "user"]

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "hi"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [
                   %{role: :user, parts: [%{text: "Hello"}]},
                   %{role: :model, parts: [%{text: "Hi"}]},
                   %{role: :user, parts: [%{text: "How are you?"}]}
                 ]
               })
    end

    test "formats tool_result messages as user role" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        tool_result_msg = List.last(decoded["messages"])
        assert tool_result_msg["role"] == "user"
        [block] = tool_result_msg["content"]
        assert block["type"] == "tool_result"
        assert block["tool_use_id"] == "toolu_abc123"

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "The weather is sunny."}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [
                   %{role: :user, parts: [%{text: "Weather?"}]},
                   %{
                     role: :model,
                     parts: [
                       %{
                         function_call: %{
                           name: "get_weather",
                           args: %{city: "London", tool_call_id: "toolu_abc123"}
                         }
                       }
                     ]
                   },
                   %{
                     role: :model,
                     parts: [
                       %{
                         function_response: %{
                           name: "get_weather",
                           response: %{result: "sunny", tool_call_id: "toolu_abc123"}
                         }
                       }
                     ]
                   }
                 ]
               })
    end
  end

  describe "generate/2 - error handling" do
    test "returns :unauthorized on 401" do
      stub_anthropic(401, %{"error" => %{"message" => "Invalid API key"}})

      assert {:error, :unauthorized} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end

    test "returns :retry_after on 429 (retry handled by ADK.LLM.generate)" do
      stub_anthropic(429, %{"error" => %{"message" => "Rate limited"}})

      assert {:retry_after, _ms, :rate_limited} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end

    test "returns :api_error on 500" do
      stub_anthropic(500, %{"error" => %{"message" => "Internal error"}})

      assert {:error, {:api_error, 500, _}} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end

    test "returns :missing_api_key when no key configured" do
      Application.delete_env(:adk, :anthropic_api_key)
      System.delete_env("ANTHROPIC_API_KEY")

      assert {:error, :missing_api_key} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end
  end

  describe "generate/2 - default model" do
    test "uses default model when nil" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "claude-sonnet-4-20250514"

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "hi"}]
        })
      end)

      assert {:ok, _} = Anthropic.generate(nil, %{messages: []})
    end
  end

  describe "generate/2 - headers" do
    test "sends x-api-key and anthropic-version headers" do
      Req.Test.stub(Anthropic, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-test-key"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} = Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end
  end

  describe "generate/2 - max_tokens" do
    test "sends max_tokens in request body" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["max_tokens"] == 1024

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [],
                 max_tokens: 1024
               })
    end

    test "uses default max_tokens when not specified" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["max_tokens"] == 4096

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} = Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end
  end

  describe "part_to_message_block parity" do
    test "dict result serialized as json" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [msg] = decoded["messages"]
        [block] = msg["content"]

        assert block["type"] == "tool_result"
        assert block["tool_use_id"] == "test_id"

        parsed = Jason.decode!(block["content"])
        assert parsed["topic"] == "travel"
        assert parsed["active"] == true

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      Anthropic.generate("claude", %{
        messages: [
          %{
            role: :model,
            parts: [
              %{
                function_response: %{
                  name: "get_topic",
                  response: %{
                    "result" => %{"topic" => "travel", "active" => true},
                    "tool_call_id" => "test_id"
                  }
                }
              }
            ]
          }
        ]
      })
    end

    test "list result serialized as json" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [msg] = decoded["messages"]
        [block] = msg["content"]

        parsed = Jason.decode!(block["content"])
        assert parsed == ["item1", "item2"]

        Req.Test.json(conn, %{})
      end)

      Anthropic.generate("claude", %{
        messages: [
          %{
            role: :model,
            parts: [
              %{
                function_response: %{
                  name: "get_items",
                  response: %{"result" => ["item1", "item2"]}
                }
              }
            ]
          }
        ]
      })
    end

    test "content array joined" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [msg] = decoded["messages"]
        [block] = msg["content"]

        assert block["content"] == "First part\nSecond part"

        Req.Test.json(conn, %{})
      end)

      Anthropic.generate("claude", %{
        messages: [
          %{
            role: :model,
            parts: [
              %{
                function_response: %{
                  name: "multi_response_tool",
                  response: %{
                    "content" => [
                      %{"type" => "text", "text" => "First part"},
                      %{"type" => "text", "text" => "Second part"}
                    ]
                  }
                }
              }
            ]
          }
        ]
      })
    end

    test "pdf document inline_data" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [msg] = decoded["messages"]
        assert length(msg["content"]) == 2
        [text_block, doc_block] = msg["content"]

        assert text_block["type"] == "text"
        assert text_block["text"] == "Summarize this"

        assert doc_block["type"] == "document"
        assert doc_block["source"]["type"] == "base64"
        assert doc_block["source"]["media_type"] == "application/pdf"
        assert doc_block["source"]["data"] == Base.encode64("fake_pdf_data")

        Req.Test.json(conn, %{})
      end)

      Anthropic.generate("claude", %{
        messages: [
          %{
            role: :user,
            parts: [
              %{text: "Summarize this"},
              %{
                inline_data: %{
                  mime_type: "application/pdf",
                  data: Base.encode64("fake_pdf_data")
                }
              }
            ]
          }
        ]
      })
    end

    test "filters images for assistant role and logs warning" do
      import ExUnit.CaptureLog

      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [msg] = decoded["messages"]
        # Only text should remain! Image filtered.
        assert length(msg["content"]) == 1
        [block] = msg["content"]

        assert block["type"] == "text"
        assert block["text"] == "I see a cat."

        Req.Test.json(conn, %{})
      end)

      log =
        capture_log(fn ->
          Anthropic.generate("claude", %{
            messages: [
              %{
                role: :model,
                parts: [
                  %{text: "I see a cat."},
                  %{
                    inline_data: %{
                      mime_type: "image/png",
                      data: Base.encode64("fake_image_data")
                    }
                  }
                ]
              }
            ]
          })
        end)

      assert log =~ "Image data is not supported in Claude for assistant turns."
    end
  end

  describe "generate/2 - tool_choice" do
    test "sends tool_choice auto" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["tool_choice"] == %{"type" => "auto"}

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 tools: [%{name: "search", description: "Search"}],
                 tool_choice: :auto
               })
    end

    test "sends tool_choice any" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["tool_choice"] == %{"type" => "any"}

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [],
                 tools: [%{name: "search", description: "Search"}],
                 tool_choice: :any
               })
    end

    test "sends tool_choice none" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["tool_choice"] == %{"type" => "none"}

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [],
                 tool_choice: :none
               })
    end

    test "sends tool_choice with specific tool name" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["tool_choice"] == %{"type" => "tool", "name" => "get_weather"}

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [],
                 tools: [%{name: "get_weather", description: "Get weather"}],
                 tool_choice: {:tool, "get_weather"}
               })
    end

    test "does not send tool_choice when not specified" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute Map.has_key?(decoded, "tool_choice")

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end
  end

  describe "generate/2 - 529 overloaded" do
    test "returns :retry_after on 529 (overloaded)" do
      stub_anthropic(529, %{"error" => %{"message" => "Overloaded"}})

      assert {:retry_after, _ms, :overloaded} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end

    test "extracts retry-after-ms header on 529" do
      Req.Test.stub(Anthropic, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after-ms", "5000")
        |> Plug.Conn.put_status(529)
        |> Req.Test.json(%{"error" => %{"message" => "Overloaded"}})
      end)

      assert {:retry_after, 5000, :overloaded} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end

    test "extracts retry-after header (seconds) on 429" do
      Req.Test.stub(Anthropic, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "3")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "Rate limited"}})
      end)

      assert {:retry_after, 3000, :rate_limited} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end
  end

  describe "generate/2 - response fields" do
    test "parses stop_reason, model, and id from response" do
      stub_anthropic(200, %{
        "id" => "msg_01XFDUDYJgAACzvnptvVoYEL",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-20250514",
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      assert resp.stop_reason == :end_turn
      assert resp.model == "claude-sonnet-4-20250514"
      assert resp.id == "msg_01XFDUDYJgAACzvnptvVoYEL"
    end

    test "parses tool_use stop_reason" do
      stub_anthropic(200, %{
        "content" => [
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "search", "input" => %{}}
        ],
        "stop_reason" => "tool_use"
      })

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})

      assert resp.stop_reason == :tool_use
    end

    test "parses max_tokens stop_reason" do
      stub_anthropic(200, %{
        "content" => [%{"type" => "text", "text" => "truncated..."}],
        "stop_reason" => "max_tokens"
      })

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})

      assert resp.stop_reason == :max_tokens
    end

    test "parses stop_sequence stop_reason" do
      stub_anthropic(200, %{
        "content" => [%{"type" => "text", "text" => "stopped here"}],
        "stop_reason" => "stop_sequence"
      })

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})

      assert resp.stop_reason == :stop_sequence
    end

    test "returns nil stop_reason for unknown values" do
      stub_anthropic(200, %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "something_new"
      })

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})

      assert resp.stop_reason == nil
    end
  end

  describe "generate/2 - is_error on tool_result" do
    test "sends is_error: true when function_response has is_error" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [msg] = decoded["messages"]
        [block] = msg["content"]

        assert block["type"] == "tool_result"
        assert block["is_error"] == true

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "I see the error"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [
                   %{
                     role: :model,
                     parts: [
                       %{
                         function_response: %{
                           name: "failing_tool",
                           id: "toolu_err1",
                           is_error: true,
                           response: %{result: "Error: something went wrong"}
                         }
                       }
                     ]
                   }
                 ]
               })
    end

    test "does not send is_error when not set" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [msg] = decoded["messages"]
        [block] = msg["content"]

        assert block["type"] == "tool_result"
        refute Map.has_key?(block, "is_error")

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [
                   %{
                     role: :model,
                     parts: [
                       %{
                         function_response: %{
                           name: "ok_tool",
                           id: "toolu_ok1",
                           response: %{result: "success"}
                         }
                       }
                     ]
                   }
                 ]
               })
    end
  end

  describe "generate/2 - metadata" do
    test "sends metadata with user_id" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["metadata"] == %{"user_id" => "user-123"}

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [],
                 metadata: %{user_id: "user-123"}
               })
    end

    test "does not send metadata when not specified" do
      Req.Test.stub(Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute Map.has_key?(decoded, "metadata")

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      end)

      assert {:ok, _} =
               Anthropic.generate("claude-sonnet-4-20250514", %{messages: []})
    end
  end

  describe "generate/2 - thinking blocks" do
    test "parses thinking blocks from response" do
      stub_anthropic(200, %{
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me consider this carefully..."},
          %{"type" => "text", "text" => "Here is my answer."}
        ],
        "stop_reason" => "end_turn"
      })

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [%{role: :user, parts: [%{text: "Think about this"}]}]
               })

      assert [%{thinking: "Let me consider this carefully..."}, %{text: "Here is my answer."}] =
               resp.content.parts
    end
  end
end
