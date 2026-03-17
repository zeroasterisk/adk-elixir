defmodule Adk.Agents.McpInstructionProviderTest do
  use ExUnit.Case, async: true

  import Mox
  alias Adk.Agents.McpInstructionProvider
  alias Adk.Mcp.SessionManager

  Mox.defmock(MockMcpSessionManager, for: Adk.Mcp.SessionManager)

  setup do
    Mox.verify_on_exit!()
    :ok
  end

  describe "invoke/1" do
    test "invoke/1 with a prompt that has no arguments" do
      # Setup mocks
      Application.put_env(:adk, :mcp_session_manager_mod, MockMcpSessionManager)
      mock_session = %{}

      expect(MockMcpSessionManager, :new, fn _ -> MockMcpSessionManager end)
      expect(MockMcpSessionManager, :create_session, fn _ -> {:ok, mock_session} end)
      expect(MockMcpSessionManager, :list_prompts, fn _, _ -> {:ok, %{prompts: [%{name: "test_prompt", arguments: nil}]}} end)
      expect(MockMcpSessionManager, :get_prompt, fn _, _, _, _ ->
        {:ok,
         %{
           messages: [
             %{content: %{type: "text", text: "instruction part 1. "}},
             %{content: %{type: "text", text: "instruction part 2"}}
           ]
         }}
      end)

      # Create provider
      provider = McpInstructionProvider.new(%{host: "localhost", port: 8000}, "test_prompt")

      # Create context
      invocation_context = %{session: %{state: %{}}}
      context = Adk.Agents.ReadonlyContext.new(invocation_context)

      # Call
      instruction = McpInstructionProvider.invoke(provider, context)

      # Assert
      assert instruction == "instruction part 1. instruction part 2"
    end
  test "invoke/1 with a prompt that has arguments" do
      # Setup mocks
      Application.put_env(:adk, :mcp_session_manager_mod, MockMcpSessionManager)
      mock_session = %{}

      expect(MockMcpSessionManager, :new, fn _ -> MockMcpSessionManager end)
      expect(MockMcpSessionManager, :create_session, fn _ -> {:ok, mock_session} end)

      expect(MockMcpSessionManager, :list_prompts, fn _, _ ->
        {:ok, %{prompts: [%{name: "test_prompt", arguments: [%{name: "arg1"}]}]}}
      end)

      expect(MockMcpSessionManager, :get_prompt, fn _, _, "test_prompt", %{"arg1" => "value1"} ->
        {:ok,
         %{
           messages: [
             %{content: %{type: "text", text: "instruction with arg1"}}
           ]
         }}
      end)

      # Create provider
      provider = McpInstructionProvider.new(%{host: "localhost", port: 8000}, "test_prompt")

      # Create context
      invocation_context = %{session: %{state: %{"arg1" => "value1", "arg2" => "value2"}}}
      context = Adk.Agents.ReadonlyContext.new(invocation_context)

      # Call
      instruction = McpInstructionProvider.invoke(provider, context)

      # Assert
      assert instruction == "instruction with arg1"
    end
  test "invoke/1 when list_prompts doesn't return the prompt" do
      # Setup mocks
      Application.put_env(:adk, :mcp_session_manager_mod, MockMcpSessionManager)
      mock_session = %{}

      expect(MockMcpSessionManager, :new, fn _ -> MockMcpSessionManager end)
      expect(MockMcpSessionManager, :create_session, fn _ -> {:ok, mock_session} end)
      expect(MockMcpSessionManager, :list_prompts, fn _, _ -> {:ok, %{prompts: []}} end)

      expect(MockMcpSessionManager, :get_prompt, fn _, _, "test_prompt", %{} ->
        {:ok, %{messages: [%{content: %{type: "text", text: "instruction"}}]}}
      end)

      # Create provider
      provider = McpInstructionProvider.new(%{host: "localhost", port: 8000}, "test_prompt")

      # Create context
      invocation_context = %{session: %{state: %{"arg1" => "value1"}}}
      context = Adk.Agents.ReadonlyContext.new(invocation_context)

      # Call
      instruction = McpInstructionProvider.invoke(provider, context)

      # Assert
      assert instruction == "instruction"
    end
  test "invoke/1 when get_prompt returns no messages" do
      # Setup mocks
      Application.put_env(:adk, :mcp_session_manager_mod, MockMcpSessionManager)
      mock_session = %{}

      expect(MockMcpSessionManager, :new, fn _ -> MockMcpSessionManager end)
      expect(MockMcpSessionManager, :create_session, fn _ -> {:ok, mock_session} end)
      expect(MockMcpSessionManager, :list_prompts, fn _, _ -> {:ok, %{prompts: []}} end)
      expect(MockMcpSessionManager, :get_prompt, fn _, _, _, _ -> {:ok, %{messages: []}} end)

      # Create provider
      provider = McpInstructionProvider.new(%{host: "localhost", port: 8000}, "test_prompt")

      # Create context
      invocation_context = %{session: %{state: %{}}}
      context = Adk.Agents.ReadonlyContext.new(invocation_context)

      # Call and assert
      assert {:error, "Failed to load MCP prompt 'test_prompt'."} ==
               McpInstructionProvider.invoke(provider, context)
    end
  test "invoke/1 ignores non-text messages" do
      # Setup mocks
      Application.put_env(:adk, :mcp_session_manager_mod, MockMcpSessionManager)
      mock_session = %{}

      expect(MockMcpSessionManager, :new, fn _ -> MockMcpSessionManager end)
      expect(MockMcpSessionManager, :create_session, fn _ -> {:ok, mock_session} end)

      expect(MockMcpSessionManager, :list_prompts, fn _, _ ->
        {:ok, %{prompts: [%{name: "test_prompt", arguments: nil}]}}
      end)

      expect(MockMcpSessionManager, :get_prompt, fn _, _, _, _ ->
        {:ok,
         %{
           messages: [
             %{content: %{type: "text", text: "instruction part 1. "}},
             %{content: %{type: "image", text: "ignored"}},
             %{content: %{type: "text", text: "instruction part 2"}}
           ]
         }}
      end)

      # Create provider
      provider = McpInstructionProvider.new(%{host: "localhost", port: 8000}, "test_prompt")

      # Create context
      invocation_context = %{session: %{state: %{}}}
      context = Adk.Agents.ReadonlyContext.new(invocation_context)

      # Call
      instruction = McpInstructionProvider.invoke(provider, context)

      # Assert
      assert instruction == "instruction part 1. instruction part 2"
    end
  end
end
