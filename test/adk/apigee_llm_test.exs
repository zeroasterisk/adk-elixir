defmodule ADK.ApigeeLlmTest do
  use ExUnit.Case, async: false

  alias ADK.ApigeeLlm

  @proxy_url "https://test.apigee.net"
  @base_model_id "gemini-2.5-flash"
  @apigee_gemini_model_id "apigee/gemini/v1/" <> @base_model_id
  @vertex_base_model_id "gemini-pro"
  @apigee_vertex_model_id "apigee/vertex_ai/v1beta/" <> @vertex_base_model_id

  setup do
    System.delete_env("GOOGLE_GENAI_USE_VERTEXAI")
    System.delete_env("GOOGLE_CLOUD_LOCATION")
    System.delete_env("GOOGLE_CLOUD_PROJECT")
    System.delete_env("APIGEE_PROXY_URL")

    # Stub Gemini
    Req.Test.stub(ADK.LLM.Gemini, fn conn ->
      send(self(), {:gemini_req, conn})
      Req.Test.json(conn, %{
        "candidates" => [%{"content" => %{"role" => "model", "parts" => [%{"text" => "Test response"}]}}]
      })
    end)
    Application.put_env(:adk, :gemini_test_plug, true)

    # Stub OpenAI
    Req.Test.stub(ADK.LLM.OpenAI, fn conn ->
      send(self(), {:openai_req, conn})
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Test response"}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15, "completion_tokens_details" => %{"reasoning_tokens" => 4}}
      })
    end)
    Application.put_env(:adk, :openai_test_plug, true)

    # Stub keys to avoid errors
    Application.put_env(:adk, :gemini_api_key, "fake_key")
    Application.put_env(:adk, :openai_api_key, "fake_key")

    on_exit(fn ->
      Application.delete_env(:adk, :gemini_test_plug)
      Application.delete_env(:adk, :openai_test_plug)
      Application.delete_env(:adk, :gemini_api_key)
      Application.delete_env(:adk, :openai_api_key)
    end)
    :ok
  end

  def request(opts \\ []) do
    Map.merge(%{
      messages: [
        %{role: :user, parts: [%{text: "Test prompt"}]}
      ],
      apigee_proxy_url: @proxy_url
    }, Map.new(opts))
  end

  test "generate content non streaming (Gemini model)" do
    {:ok, response} = ApigeeLlm.generate(@apigee_gemini_model_id, request())

    assert [%{text: "Test response"}] = response.content.parts
    assert response.content.role == :model

    assert_receive {:gemini_req, conn}
    assert conn.host == "test.apigee.net"
    assert conn.request_path == "/v1/models/#{@base_model_id}:generateContent"
  end

  test "generate content with custom headers" do
    req = request(custom_headers: [{"x-custom-header", "custom-value"}])
    {:ok, _response} = ApigeeLlm.generate(@apigee_gemini_model_id, req)

    assert_receive {:gemini_req, conn}
    assert Plug.Conn.get_req_header(conn, "x-custom-header") == ["custom-value"]
  end

  test "vertex model path parsing" do
    System.put_env("GOOGLE_CLOUD_PROJECT", "test-project")
    System.put_env("GOOGLE_CLOUD_LOCATION", "test-location")

    {:ok, _} = ApigeeLlm.generate(@apigee_vertex_model_id, request())

    assert_receive {:gemini_req, conn}
    assert conn.host == "test.apigee.net"
    assert conn.request_path == "/v1beta/projects/test-project/locations/test-location/publishers/google/models/#{@vertex_base_model_id}:generateContent"
  end

  test "proxy url from env variable" do
    System.put_env("APIGEE_PROXY_URL", "https://env.proxy.url")
    # pass request without apigee_proxy_url
    req = %{messages: [%{role: :user, parts: [%{text: "Test"}]}]}
    {:ok, _} = ApigeeLlm.generate("apigee/gemini-2.5-flash", req)

    assert_receive {:gemini_req, conn}
    assert conn.host == "env.proxy.url"
    assert conn.request_path == "/v1beta/models/gemini-2.5-flash:generateContent"
  end

  test "vertex model missing project or location raises error" do
    System.delete_env("GOOGLE_CLOUD_PROJECT")
    System.delete_env("GOOGLE_CLOUD_LOCATION")
    assert_raise ArgumentError, ~r/environment variable must be set/, fn ->
      ApigeeLlm.generate("apigee/vertex_ai/gemini-2.5-flash", request())
    end
  end

  test "invalid model strings raise argument error" do
    Enum.each([
      "apigee/",
      "apigee",
      "gemini-pro",
      "apigee/vertex_ai/v1/model/extra",
      "apigee/unknown/model"
    ], fn invalid_model ->
      assert_raise ArgumentError, ~r/Invalid model string/, fn ->
        ApigeeLlm.generate(invalid_model, request())
      end
    end)
  end

  test "validate model for chat completion providers" do
    {:ok, _} = ApigeeLlm.generate("apigee/openai/gpt-4o", request())
    assert_receive {:openai_req, conn}
    assert conn.host == "test.apigee.net"
    assert conn.request_path == "/v1/chat/completions"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fake_key"]
  end

  test "api type resolution via apigee_api_type" do
    req = request(apigee_api_type: :chat_completions)
    {:ok, _} = ApigeeLlm.generate("apigee/gemini/pro", req)

    assert_receive {:openai_req, conn}
    assert conn.request_path == "/v1/chat/completions"
  end

  test "parse response usage metadata including reasoning tokens" do
    {:ok, response} = ApigeeLlm.generate("apigee/openai/gpt-4o", request())
    assert response.usage_metadata["total_tokens"] == 15
    assert response.usage_metadata["completion_tokens_details"]["reasoning_tokens"] == 4
  end

end
