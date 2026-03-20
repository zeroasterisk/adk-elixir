# Mock MCP server for testing — runs as a standalone script via stdio.
# Reads JSON-RPC from stdin, writes responses to stdout.

Mix.install([{:jason, "~> 1.4"}])

defmodule MockMCPServer do
  def run do
    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      line = String.trim(line)

      case Jason.decode(line) do
        {:ok, msg} -> handle(msg)
        _ -> :ignore
      end
    end)
  end

  defp handle(%{"id" => id, "method" => "initialize"}) do
    respond(id, %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "MockMCPServer", "version" => "0.1.0"}
    })
  end

  defp handle(%{"method" => "notifications/initialized"}), do: :ok

  defp handle(%{"id" => id, "method" => "tools/list"}) do
    respond(id, %{
      "tools" => [
        %{
          "name" => "echo",
          "description" => "Echo the input message",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "message" => %{"type" => "string", "description" => "Message to echo"}
            },
            "required" => ["message"]
          }
        },
        %{
          "name" => "add",
          "description" => "Add two numbers",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "a" => %{"type" => "number"},
              "b" => %{"type" => "number"}
            },
            "required" => ["a", "b"]
          }
        }
      ]
    })
  end

  defp handle(%{"id" => id, "method" => "tools/call", "params" => %{"name" => "echo", "arguments" => args}}) do
    respond(id, %{
      "content" => [%{"type" => "text", "text" => args["message"] || ""}],
      "isError" => false
    })
  end

  defp handle(%{"id" => id, "method" => "tools/call", "params" => %{"name" => "add", "arguments" => args}}) do
    result = (args["a"] || 0) + (args["b"] || 0)

    respond(id, %{
      "content" => [%{"type" => "text", "text" => to_string(result)}],
      "isError" => false
    })
  end

  defp handle(%{"id" => id, "method" => "tools/call", "params" => %{"name" => name}}) do
    respond_error(id, -32601, "Unknown tool: #{name}")
  end

  defp handle(_), do: :ok

  defp respond(id, result) do
    msg = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    IO.puts(msg)
  end

  defp respond_error(id, code, message) do
    msg = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
    IO.puts(msg)
  end
end

MockMCPServer.run()
