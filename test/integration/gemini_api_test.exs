defmodule ADK.Integration.GeminiApiTest do
  @moduledoc """
  Integration tests that hit the real Gemini API.

  ## Running

      GEMINI_API_KEY=your-key mix test test/integration/ --include integration

  These tests are excluded by default. They use `gemini-flash-latest`
  to keep model references evergreen.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  @model "gemini-flash-latest"

  setup do
    # Use real Gemini backend for integration tests
    prev_backend = Application.get_env(:adk, :llm_backend)
    prev_key = Application.get_env(:adk, :gemini_api_key)
    prev_token = Application.get_env(:adk, :gemini_bearer_token)

    Application.put_env(:adk, :llm_backend, ADK.LLM.Gemini)

    # Support both API key and service account bearer token.
    # Prefer GOOGLE_APPLICATION_CREDENTIALS (bearer token) over GEMINI_API_KEY
    # since API keys may be invalid/expired.
    has_auth =
      cond do
        System.get_env("GOOGLE_APPLICATION_CREDENTIALS") != nil ->
          # Auto-generate bearer token from service account (most reliable)
          case System.cmd("python3", ["test/integration/get_bearer_token.py"],
                 env: [{"GOOGLE_APPLICATION_CREDENTIALS", System.get_env("GOOGLE_APPLICATION_CREDENTIALS")}]
               ) do
            {token, 0} ->
              Application.put_env(:adk, :gemini_bearer_token, String.trim(token))
              # Clear any potentially invalid API key so auth/0 uses bearer token
              Application.delete_env(:adk, :gemini_api_key)
              System.delete_env("GEMINI_API_KEY")
              true

            _ ->
              # Fall back to API key if bearer token generation fails
              System.get_env("GEMINI_API_KEY") != nil or System.get_env("GEMINI_BEARER_TOKEN") != nil
          end

        System.get_env("GEMINI_BEARER_TOKEN") != nil ->
          true

        System.get_env("GEMINI_API_KEY") != nil ->
          true

        true ->
          false
      end

    on_exit(fn ->
      Application.put_env(:adk, :llm_backend, prev_backend)
      if prev_key, do: Application.put_env(:adk, :gemini_api_key, prev_key), else: Application.delete_env(:adk, :gemini_api_key)
      if prev_token, do: Application.put_env(:adk, :gemini_bearer_token, prev_token), else: Application.delete_env(:adk, :gemini_bearer_token)
    end)

    if has_auth, do: :ok, else: {:error, "No GEMINI_API_KEY, GEMINI_BEARER_TOKEN, or GOOGLE_APPLICATION_CREDENTIALS set"}
  end

  describe "single-turn" do
    test "simple question/answer" do
      request = %{
        instruction: "You are a helpful assistant. Reply briefly.",
        messages: [%{role: :user, parts: [%{text: "What is 2 + 2? Reply with just the number."}]}],
        tools: []
      }

      assert {:ok, response} = ADK.LLM.Gemini.generate(@model, request)
      assert %{content: %{role: :model, parts: parts}} = response
      assert length(parts) > 0
      text = hd(parts) |> Map.get(:text, "")
      assert text =~ "4"
    end
  end

  describe "multi-turn conversation" do
    test "maintains context across turns" do
      turn1 = %{
        instruction: "You are a helpful assistant. Be brief.",
        messages: [
          %{role: :user, parts: [%{text: "My name is Zephyr. Remember it."}]}
        ],
        tools: []
      }

      assert {:ok, resp1} = ADK.LLM.Gemini.generate(@model, turn1)
      model_parts1 = resp1.content.parts

      turn2 = %{
        instruction: "You are a helpful assistant. Be brief.",
        messages: [
          %{role: :user, parts: [%{text: "My name is Zephyr. Remember it."}]},
          %{role: :model, parts: model_parts1},
          %{role: :user, parts: [%{text: "What is my name?"}]}
        ],
        tools: []
      }

      assert {:ok, resp2} = ADK.LLM.Gemini.generate(@model, turn2)
      text = hd(resp2.content.parts) |> Map.get(:text, "")
      assert text =~ "Zephyr"
    end
  end

  describe "tool use (function calling)" do
  @tag skip: "upstream Gemini API thought_signature bug"
    test "function call and response round-trip" do
      tools = [
        %{
          name: "get_weather",
          description: "Get the current weather for a city",
          parameters: %{
            type: "object",
            properties: %{
              city: %{type: "string", description: "City name"}
            },
            required: ["city"]
          }
        }
      ]

      request = %{
        instruction: "Use the get_weather tool to answer weather questions.",
        messages: [
          %{role: :user, parts: [%{text: "What's the weather in Paris?"}]}
        ],
        tools: tools
      }

      assert {:ok, response} = ADK.LLM.Gemini.generate(@model, request)

      # Should contain a function call
      fc_parts = Enum.filter(response.content.parts, fn
        %{function_call: _} -> true
        _ -> false
      end)

      assert length(fc_parts) > 0
      %{function_call: %{name: name, args: args}} = hd(fc_parts)
      assert name == "get_weather"
      assert is_map(args)

      IO.inspect(response.content.parts, label: "PARTS")
      # Now send function response back
      request2 = %{
        instruction: "Use the get_weather tool to answer weather questions.",
        messages: [
          %{role: :user, parts: [%{text: "What's the weather in Paris?"}]},
          %{role: :model, parts: response.content.parts},
          %{role: :user, parts: [%{function_response: %{name: "get_weather", response: %{"temperature" => "22°C", "condition" => "sunny"}}}]}
        ],
        tools: tools
      }

      assert {:ok, resp2} = ADK.LLM.Gemini.generate(@model, request2)
      text = hd(resp2.content.parts) |> Map.get(:text, "")
      # Should mention the weather data we provided
      assert text =~ ~r/22|sunny|Paris/i
    end
  end

  describe "agent transfer" do
    test "sub-agent delegation via runner" do
      weather_tool =
        ADK.Tool.FunctionTool.new("get_weather",
          description: "Get weather",
          parameters: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]},
          func: fn _ctx, _args -> {:ok, "Sunny, 25°C"} end
        )

      weather_agent =
        ADK.Agent.LlmAgent.new(
          name: "weather_agent",
          model: @model,
          instruction: "You are a weather assistant. Use the get_weather tool. Be brief.",
          description: "Handles weather queries",
          tools: [weather_tool]
        )

      router_agent =
        ADK.Agent.LlmAgent.new(
          name: "router",
          model: @model,
          instruction: "You are a router. For weather questions, delegate to weather_agent. Be brief.",
          sub_agents: [weather_agent]
        )

      runner = %ADK.Runner{app_name: "integration_test", agent: router_agent}
      events = ADK.Runner.run(runner, "user1", "sess-#{System.unique_integer([:positive])}", "What's the weather?")

      assert is_list(events)
      assert length(events) > 0

      # At least one event should have text content
      texts =
        events
        |> Enum.flat_map(fn e ->
          case e.content do
            %{parts: parts} -> Enum.flat_map(parts, fn
              %{text: t} when t != "" -> [t]
              _ -> []
            end)
            _ -> []
          end
        end)

      assert length(texts) > 0
    end
  end

  describe "error handling" do
    test "bad model name returns error" do
      request = %{
        messages: [%{role: :user, parts: [%{text: "hi"}]}],
        tools: []
      }

      assert {:error, _} = ADK.LLM.Gemini.generate("nonexistent-model-xyz-999", request)
    end

    test "invalid request structure still gets a response or error" do
      request = %{messages: [], tools: []}
      result = ADK.LLM.Gemini.generate(@model, request)
      # Either ok with empty or error — both are valid
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
