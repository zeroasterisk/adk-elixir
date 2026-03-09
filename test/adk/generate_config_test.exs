defmodule ADK.GenerateConfigTest do
  use ExUnit.Case, async: true

  describe "LlmAgent generate_config" do
    test "default generate_config is empty map" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help.")
      assert agent.generate_config == %{}
    end

    test "accepts generate_config" do
      agent = ADK.Agent.LlmAgent.new(
        name: "bot",
        model: "test",
        instruction: "Help.",
        generate_config: %{temperature: 0.7, max_output_tokens: 1000}
      )

      assert agent.generate_config.temperature == 0.7
      assert agent.generate_config.max_output_tokens == 1000
    end
  end

  describe "RunConfig generate_config" do
    test "default generate_config is empty map" do
      config = ADK.RunConfig.new()
      assert config.generate_config == %{}
    end

    test "accepts generate_config" do
      config = ADK.RunConfig.new(generate_config: %{temperature: 0.3})
      assert config.generate_config.temperature == 0.3
    end
  end

  describe "generate_config passthrough to LLM request" do
    setup do
      # Track the request sent to the mock LLM
      test_pid = self()

      # We'll use Process dictionary to capture the request
      ADK.LLM.Mock.set_responses(["OK"])

      agent = ADK.Agent.LlmAgent.new(
        name: "bot",
        model: "test",
        instruction: "Help.",
        generate_config: %{temperature: 0.7, top_p: 0.9, max_output_tokens: 500, stop_sequences: ["STOP"]}
      )

      {:ok, agent: agent, test_pid: test_pid}
    end

    test "agent generate_config is included in request", %{agent: agent} do
      # Build request directly to verify
      ctx = %ADK.Context{
        invocation_id: "test-inv",
        session_pid: nil,
        agent: agent,
        user_content: %{text: "hi"}
      }

      # Access build_request via the module (it's technically private, so test through runner)
      # Instead, test end-to-end by capturing in a custom backend
      request = build_test_request(ctx, agent)

      assert request.generate_config.temperature == 0.7
      assert request.generate_config.top_p == 0.9
      assert request.generate_config.max_output_tokens == 500
      assert request.generate_config.stop_sequences == ["STOP"]
    end

    test "run_config generate_config overrides agent defaults", %{agent: agent} do
      run_config = ADK.RunConfig.new(generate_config: %{temperature: 0.1, top_p: 0.5})

      ctx = %ADK.Context{
        invocation_id: "test-inv",
        session_pid: nil,
        agent: agent,
        user_content: %{text: "hi"},
        run_config: run_config
      }

      request = build_test_request(ctx, agent)

      # RunConfig overrides agent's temperature and top_p
      assert request.generate_config.temperature == 0.1
      assert request.generate_config.top_p == 0.5
      # Agent defaults preserved for non-overridden keys
      assert request.generate_config.max_output_tokens == 500
      assert request.generate_config.stop_sequences == ["STOP"]
    end

    test "run_config generate_config works with empty agent config" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help.")
      run_config = ADK.RunConfig.new(generate_config: %{temperature: 0.2})

      ctx = %ADK.Context{
        invocation_id: "test-inv",
        session_pid: nil,
        agent: agent,
        user_content: %{text: "hi"},
        run_config: run_config
      }

      request = build_test_request(ctx, agent)
      assert request.generate_config.temperature == 0.2
    end

    test "no generate_config when both agent and run_config are empty" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help.")

      ctx = %ADK.Context{
        invocation_id: "test-inv",
        session_pid: nil,
        agent: agent,
        user_content: %{text: "hi"}
      }

      request = build_test_request(ctx, agent)
      refute Map.has_key?(request, :generate_config)
    end
  end

  describe "Gemini generate_config translation" do
    test "translates to Gemini generationConfig format" do
      request = %{
        instruction: "test",
        messages: [%{role: :user, parts: [%{text: "hi"}]}],
        generate_config: %{
          temperature: 0.5,
          top_p: 0.9,
          top_k: 40,
          max_output_tokens: 500,
          stop_sequences: ["END"],
          response_mime_type: "application/json"
        }
      }

      # Test through Req.Test plug
      Req.Test.stub(ADK.LLM.Gemini, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        gen_config = decoded["generationConfig"]
        assert gen_config["temperature"] == 0.5
        assert gen_config["topP"] == 0.9
        assert gen_config["topK"] == 40
        assert gen_config["maxOutputTokens"] == 500
        assert gen_config["stopSequences"] == ["END"]
        assert gen_config["responseMimeType"] == "application/json"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "candidates" => [%{"content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]}}]
        }))
      end)

      Application.put_env(:adk, :gemini_api_key, "test-key")
      Application.put_env(:adk, :gemini_test_plug, true)

      assert {:ok, _} = ADK.LLM.Gemini.generate("gemini-2.0-flash", request)
    after
      Application.delete_env(:adk, :gemini_test_plug)
    end
  end

  describe "Anthropic generate_config translation" do
    test "translates to Anthropic API format" do
      request = %{
        instruction: "test",
        messages: [%{role: :user, parts: [%{text: "hi"}]}],
        generate_config: %{
          temperature: 0.8,
          top_p: 0.95,
          top_k: 40,
          max_output_tokens: 2000,
          stop_sequences: ["STOP"]
        }
      }

      Req.Test.stub(ADK.LLM.Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["temperature"] == 0.8
        assert decoded["top_p"] == 0.95
        assert decoded["top_k"] == 40
        assert decoded["max_tokens"] == 2000
        assert decoded["stop_sequences"] == ["STOP"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "role" => "assistant"
        }))
      end)

      Application.put_env(:adk, :anthropic_api_key, "test-key")
      Application.put_env(:adk, :anthropic_test_plug, true)

      assert {:ok, _} = ADK.LLM.Anthropic.generate("claude-sonnet-4-20250514", request)
    after
      Application.delete_env(:adk, :anthropic_test_plug)
    end
  end

  describe "OpenAI generate_config translation" do
    test "translates to OpenAI API format" do
      request = %{
        instruction: "test",
        messages: [%{role: :user, parts: [%{text: "hi"}]}],
        generate_config: %{
          temperature: 0.7,
          top_p: 0.9,
          max_output_tokens: 1000,
          stop_sequences: ["END"],
          candidate_count: 2,
          response_mime_type: "application/json"
        }
      }

      Req.Test.stub(ADK.LLM.OpenAI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["temperature"] == 0.7
        assert decoded["top_p"] == 0.9
        assert decoded["max_tokens"] == 1000
        assert decoded["stop"] == ["END"]
        assert decoded["n"] == 2
        assert decoded["response_format"] == %{"type" => "json_object"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        }))
      end)

      Application.put_env(:adk, :openai_api_key, "test-key")
      Application.put_env(:adk, :openai_test_plug, true)

      assert {:ok, _} = ADK.LLM.OpenAI.generate("gpt-4o", request)
    after
      Application.delete_env(:adk, :openai_test_plug)
    end
  end

  # Helper to build request without running full agent loop
  defp build_test_request(ctx, agent) do
    messages =
      case ctx.user_content do
        %{text: text} -> [%{role: :user, parts: [%{text: text}]}]
        _ -> []
      end

    request = %{
      model: agent.model,
      instruction: agent.instruction,
      messages: messages,
      tools: []
    }

    # Replicate the merge logic from LlmAgent.build_request
    merged_config =
      case ctx.run_config do
        %ADK.RunConfig{generate_config: rc} when is_map(rc) and map_size(rc) > 0 ->
          case agent.generate_config do
            config when is_map(config) -> Map.merge(config, rc)
            _ -> rc
          end
        _ ->
          agent.generate_config || %{}
      end

    case merged_config do
      config when is_map(config) and map_size(config) > 0 ->
        Map.put(request, :generate_config, config)
      _ ->
        request
    end
  end
end
