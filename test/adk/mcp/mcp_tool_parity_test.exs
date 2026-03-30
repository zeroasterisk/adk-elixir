defmodule ADK.MCP.McpToolParityTest do
  @moduledoc """
  Parity tests for MCP tool behaviors, mirroring Python ADK's
  `tests/unittests/tools/mcp_tool/test_mcp_tool.py`.

  Tests:
  - Tool initialization / declaration from MCP tool definition
  - Invoking tool with correct arguments over MCP client
  - Returning success response text
  - Handling explicit error responses (`isError: true`)

  Roadmap deviations (Omitted):
  - No LangChain, CrewAI, Apigee, Vertex AI Search Grounding, AudioCacheManager, Realtime streaming/VAD.
  - No `BaseAuthenticatedTool` features (OAuth2, API keys, basic auth) since
    Elixir currently only supports stdio-based MCP client, not HTTP.
  - No `render_ui_widgets` generation (UI actions map differently in Elixir).
  - No `require_confirmation` builtin property (Elixir provides `Confirmation.new` wrapper tool).
  """
  use ExUnit.Case, async: true

  alias ADK.Tool.FunctionTool
  alias ADK.MCP.ToolAdapter

  # A mock MCP client GenServer that responds to the same calls as ADK.MCP.Client
  defmodule MockMcpClient do
    use GenServer

    def start_link(responses) do
      GenServer.start_link(__MODULE__, responses)
    end

    @impl true
    def init(responses) do
      {:ok, responses}
    end

    @impl true
    def handle_call({:call_tool, name, args}, _from, responses) do
      case Map.fetch(responses, {name, args}) do
        {:ok, result} ->
          {:reply, {:ok, result}, responses}

        :error ->
          {:reply, {:error, :not_found}, responses}
      end
    end
  end

  describe "MCP tool declaration" do
    test "correctly builds FunctionTool from MCP definition" do
      mcp_def = %{
        "name" => "test_tool",
        "description" => "Test tool description",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "param1" => %{"type" => "string"}
          },
          "required" => ["param1"]
        }
      }

      tool = ToolAdapter.to_function_tool(self(), mcp_def)

      assert tool.name == "test_tool"
      assert tool.description == "Test tool description"
      assert tool.parameters["properties"]["param1"]["type"] == "string"

      # Also verify ADK.Tool.declaration/1 works on it
      decl = ADK.Tool.declaration(tool)
      assert decl.name == "test_tool"
      assert decl.description == "Test tool description"
      assert decl.parameters["required"] == ["param1"]
    end

    test "handles missing description gracefully" do
      mcp_def = %{
        "name" => "test_tool",
        "inputSchema" => %{"type" => "object"}
      }

      tool = ToolAdapter.to_function_tool(self(), mcp_def)
      assert tool.name == "test_tool"
      assert tool.description == ""
    end

    test "handles empty inputSchema gracefully" do
      mcp_def = %{
        "name" => "test_tool",
        "description" => "A tool"
      }

      tool = ToolAdapter.to_function_tool(self(), mcp_def)
      assert tool.parameters == %{}
    end
  end

  describe "MCP tool invocation" do
    setup do
      # Set up mock responses for the client
      responses = %{
        {"success_tool", %{"param1" => "value1"}} => %{
          "content" => [%{"type" => "text", "text" => "tool output text"}],
          "isError" => false
        },
        {"error_tool", %{}} => %{
          "content" => [%{"type" => "text", "text" => "an error occurred"}],
          "isError" => true
        },
        {"weird_tool", %{}} => %{
          "content" => [%{"text" => "plain text field instead of typed"}],
          "isError" => false
        }
      }

      {:ok, client} = MockMcpClient.start_link(responses)
      %{client: client}
    end

    test "runs successfully and extracts text content", %{client: client} do
      mcp_def = %{"name" => "success_tool", "description" => "desc"}
      tool = ToolAdapter.to_function_tool(client, mcp_def)

      ctx = ADK.ToolContext.new(%ADK.Context{app_name: "test"}, "call_123", tool)

      # The tool delegates to ADK.MCP.Client.call_tool, which uses GenServer.call
      result = FunctionTool.run(tool, ctx, %{"param1" => "value1"})

      assert {:ok, "tool output text"} = result
    end

    test "extracts text when type field is omitted", %{client: client} do
      mcp_def = %{"name" => "weird_tool"}
      tool = ToolAdapter.to_function_tool(client, mcp_def)

      ctx = ADK.ToolContext.new(%ADK.Context{app_name: "test"}, "call_124", tool)

      result = FunctionTool.run(tool, ctx, %{})
      assert {:ok, "plain text field instead of typed"} = result
    end

    test "returns {:error, msg} when isError is true", %{client: client} do
      mcp_def = %{"name" => "error_tool", "description" => "desc"}
      tool = ToolAdapter.to_function_tool(client, mcp_def)

      ctx = ADK.ToolContext.new(%ADK.Context{app_name: "test"}, "call_125", tool)

      result = FunctionTool.run(tool, ctx, %{})

      assert {:error, "an error occurred"} = result
    end
  end
end
