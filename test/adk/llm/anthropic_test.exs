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

    test "returns :rate_limited on 429" do
      stub_anthropic(429, %{"error" => %{"message" => "Rate limited"}})

      assert {:error, :rate_limited} =
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
end
