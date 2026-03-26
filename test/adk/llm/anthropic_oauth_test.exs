defmodule ADK.LLM.AnthropicOAuthTest do
  use ExUnit.Case, async: false

  alias ADK.LLM.Anthropic

  setup do
    # Clean slate — no credentials
    Application.delete_env(:adk, :anthropic_api_key)
    Application.delete_env(:adk, :anthropic_oauth_token)
    Application.delete_env(:adk, :anthropic_auto_discover)
    Application.put_env(:adk, :anthropic_test_plug, true)

    on_exit(fn ->
      Application.delete_env(:adk, :anthropic_api_key)
      Application.delete_env(:adk, :anthropic_oauth_token)
      Application.delete_env(:adk, :anthropic_auto_discover)
      Application.delete_env(:adk, :anthropic_test_plug)
    end)

    :ok
  end

  describe "resolve_auth/0" do
    test "prefers OAuth token config over API key" do
      Application.put_env(:adk, :anthropic_oauth_token, "sk-ant-sid02-test-oauth")
      Application.put_env(:adk, :anthropic_api_key, "sk-ant-api-test")

      assert {:ok, {:oauth, "sk-ant-sid02-test-oauth"}} = Anthropic.resolve_auth()
    end

    test "falls back to API key when no OAuth token" do
      Application.put_env(:adk, :anthropic_api_key, "sk-ant-api-test")

      assert {:ok, {:api_key, "sk-ant-api-test"}} = Anthropic.resolve_auth()
    end

    test "returns error when no credentials" do
      # Ensure env vars don't leak in
      System.delete_env("ANTHROPIC_OAUTH_TOKEN")
      System.delete_env("ANTHROPIC_API_KEY")
      Application.put_env(:adk, :anthropic_auto_discover, false)

      assert {:error, :missing_api_key} = Anthropic.resolve_auth()
    end

    test "checks ANTHROPIC_OAUTH_TOKEN env var" do
      System.put_env("ANTHROPIC_OAUTH_TOKEN", "sk-ant-sid02-env-oauth")

      on_exit(fn -> System.delete_env("ANTHROPIC_OAUTH_TOKEN") end)

      assert {:ok, {:oauth, "sk-ant-sid02-env-oauth"}} = Anthropic.resolve_auth()
    end

    test "auto-discovers CLAUDE_AI_SESSION_KEY when enabled" do
      Application.put_env(:adk, :anthropic_auto_discover, true)
      System.put_env("CLAUDE_AI_SESSION_KEY", "sk-ant-sid02-claude-cli")

      on_exit(fn -> System.delete_env("CLAUDE_AI_SESSION_KEY") end)

      assert {:ok, {:oauth, "sk-ant-sid02-claude-cli"}} = Anthropic.resolve_auth()
    end

    test "does not auto-discover CLAUDE_AI_SESSION_KEY when disabled" do
      Application.put_env(:adk, :anthropic_auto_discover, false)
      System.put_env("CLAUDE_AI_SESSION_KEY", "sk-ant-sid02-claude-cli")
      System.delete_env("ANTHROPIC_OAUTH_TOKEN")
      System.delete_env("ANTHROPIC_API_KEY")

      on_exit(fn -> System.delete_env("CLAUDE_AI_SESSION_KEY") end)

      assert {:error, :missing_api_key} = Anthropic.resolve_auth()
    end
  end

  describe "OAuth auth headers" do
    test "sends Authorization Bearer header with OAuth token" do
      Application.put_env(:adk, :anthropic_oauth_token, "sk-ant-sid02-test-oauth")

      Req.Test.stub(Anthropic, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Bearer sk-ant-sid02-test-oauth"
               ]

        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
        # Should NOT have x-api-key
        assert Plug.Conn.get_req_header(conn, "x-api-key") == []

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "Hello from OAuth!"}]
        })
      end)

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      assert [%{text: "Hello from OAuth!"}] = resp.content.parts
    end

    test "sends x-api-key header with API key auth" do
      Application.put_env(:adk, :anthropic_api_key, "sk-ant-api-test")

      Req.Test.stub(Anthropic, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-api-test"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
        # Should NOT have Authorization
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "Hello from API key!"}]
        })
      end)

      assert {:ok, resp} =
               Anthropic.generate("claude-sonnet-4-20250514", %{
                 messages: [%{role: :user, parts: [%{text: "Hi"}]}]
               })

      assert [%{text: "Hello from API key!"}] = resp.content.parts
    end
  end
end
