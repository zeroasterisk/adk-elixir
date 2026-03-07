defmodule ADK.LLM.OpenAITest do
  use ExUnit.Case, async: true

  alias ADK.LLM.OpenAI

  setup do
    Application.put_env(:adk, :openai_api_key, "sk-test-key")
    Application.put_env(:adk, :openai_test_plug, true)
    Application.delete_env(:adk, :openai_base_url)

    on_exit(fn ->
      Application.delete_env(:adk, :openai_api_key)
      Application.delete_env(:adk, :openai_test_plug)
      Application.delete_env(:adk, :openai_base_url)
    end)

    :ok
  end

  defp stub_openai(status, body) do
    Req.Test.stub(OpenAI, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  describe "generate/2 - text response" do
    test "returns parsed text response" do
      stub_openai(200, %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "Hello! How can I help?"
            }
          }
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 8
        }
      })

      assert {:ok, resp} =
               OpenAI.generate("gpt-4o", %{
                 instruction: "Be helpful.",
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      assert resp.content.role == :model
      assert [%{text: "Hello! How can I help?"}] = resp.content.parts
      assert resp.usage_metadata["prompt_tokens"] == 10
    end
  end

  describe "generate/2 - function call response" do
    test "returns parsed tool calls" do
      stub_openai(200, %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_abc123",
                  "type" => "function",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => ~s({"city":"London"})
                  }
                }
              ]
            }
          }
        ]
      })

      assert {:ok, resp} =
               OpenAI.generate("gpt-4o", %{
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
      assert fc.id == "call_abc123"
    end
  end

  describe "generate/2 - system instruction" do
    test "sends system message in request body" do
      Req.Test.stub(OpenAI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        messages = decoded["messages"]
        assert [%{"role" => "system", "content" => "You are a pirate."} | _] = messages

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "Arrr!"}}
          ]
        })
      end)

      assert {:ok, _} =
               OpenAI.generate("gpt-4o", %{
                 instruction: "You are a pirate.",
                 messages: [%{role: :user, parts: [%{text: "Hello"}]}]
               })
    end
  end

  describe "generate/2 - tool declarations" do
    test "sends tools in OpenAI format" do
      Req.Test.stub(OpenAI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        tools = decoded["tools"]
        assert length(tools) == 2
        assert Enum.all?(tools, &(&1["type"] == "function"))
        assert Enum.any?(tools, &(&1["function"]["name"] == "search"))

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "ok"}}
          ]
        })
      end)

      assert {:ok, _} =
               OpenAI.generate("gpt-4o", %{
                 messages: [%{role: :user, parts: [%{text: "test"}]}],
                 tools: [
                   %{name: "search", description: "Search the web"},
                   %{name: "calculate", description: "Do math", parameters: %{type: "object"}}
                 ]
               })
    end
  end

  describe "generate/2 - message formatting" do
    test "maps ADK roles to OpenAI roles" do
      Req.Test.stub(OpenAI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        roles = Enum.map(decoded["messages"], & &1["role"])
        assert roles == ["user", "assistant", "user"]

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "hi"}}
          ]
        })
      end)

      assert {:ok, _} =
               OpenAI.generate("gpt-4o", %{
                 messages: [
                   %{role: :user, parts: [%{text: "Hello"}]},
                   %{role: :model, parts: [%{text: "Hi"}]},
                   %{role: :user, parts: [%{text: "How are you?"}]}
                 ]
               })
    end
  end

  describe "generate/2 - error handling" do
    test "returns :unauthorized on 401" do
      stub_openai(401, %{"error" => %{"message" => "Invalid API key"}})
      assert {:error, :unauthorized} = OpenAI.generate("gpt-4o", %{messages: []})
    end

    test "returns :rate_limited on 429" do
      stub_openai(429, %{"error" => %{"message" => "Rate limited"}})
      assert {:error, :rate_limited} = OpenAI.generate("gpt-4o", %{messages: []})
    end

    test "returns :api_error on 500" do
      stub_openai(500, %{"error" => %{"message" => "Internal error"}})
      assert {:error, {:api_error, 500, _}} = OpenAI.generate("gpt-4o", %{messages: []})
    end

    test "returns :missing_api_key when no key configured" do
      Application.delete_env(:adk, :openai_api_key)
      System.delete_env("OPENAI_API_KEY")

      assert {:error, :missing_api_key} = OpenAI.generate("gpt-4o", %{messages: []})
    end
  end

  describe "generate/2 - default model" do
    test "uses default model when nil" do
      Req.Test.stub(OpenAI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "gpt-4o"

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "hi"}}
          ]
        })
      end)

      assert {:ok, _} = OpenAI.generate(nil, %{messages: []})
    end
  end

  describe "generate/2 - base_url override" do
    test "uses configured base_url" do
      Application.put_env(:adk, :openai_base_url, "http://localhost:11434/v1")

      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "ollama response"}}
          ]
        })
      end)

      assert {:ok, resp} = OpenAI.generate("llama3", %{messages: []})
      assert [%{text: "ollama response"}] = resp.content.parts
    end
  end

  describe "generate/2 - auth header" do
    test "sends Bearer token in authorization header" do
      Req.Test.stub(OpenAI, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer sk-test-key"]

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "ok"}}
          ]
        })
      end)

      assert {:ok, _} = OpenAI.generate("gpt-4o", %{messages: []})
    end
  end
end
