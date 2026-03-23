defmodule ADK.Tool.OpenApiTool.RestApiToolTest do
  use ExUnit.Case, async: true
  alias ADK.Tool.OpenApiTool.RestApiTool
  alias ADK.Tool.OpenApiTool.SpecParser.{OperationEndpoint, ApiParameter, ParsedOperation}

  describe "init" do
    test "from_parsed_operation" do
      endpoint = %OperationEndpoint{base_url: "https://example.com", path: "/test", method: "GET"}
      operation = %{"operationId" => "testOperation", "description" => "Test operation"}

      parsed = %ParsedOperation{
        name: "test_tool",
        description: "Test Tool",
        endpoint: endpoint,
        operation: operation,
        parameters: [],
        auth_scheme: %{type: "apiKey"},
        auth_credential: %{apiKey: "test"}
      }

      tool = RestApiTool.from_parsed_operation(parsed)
      assert tool.name == "test_tool"
      assert tool.description == "Test Tool"
      assert tool.endpoint == endpoint
      assert tool.operation == operation
      assert tool.auth_scheme == %{type: "apiKey"}
      assert tool.auth_credential == %{apiKey: "test"}
    end
  end

  describe "snake_to_lower_camel" do
    test "converts correctly" do
      assert RestApiTool.snake_to_lower_camel("single") == "single"
      assert RestApiTool.snake_to_lower_camel("two_words") == "twoWords"
      assert RestApiTool.snake_to_lower_camel("three_word_example") == "threeWordExample"
      assert RestApiTool.snake_to_lower_camel("") == ""
      assert RestApiTool.snake_to_lower_camel("alreadyCamelCase") == "alreadyCamelCase"
    end
  end

  describe "prepare_request_params" do
    setup do
      endpoint = %OperationEndpoint{base_url: "https://example.com", path: "/test", method: "GET"}
      operation = %{"operationId" => "test_op"}
      tool = %RestApiTool{name: "test_tool", endpoint: endpoint, operation: operation}
      {:ok, tool: tool}
    end

    test "basic query and body params", %{tool: tool} do
      params = [
        %ApiParameter{original_name: "param1", py_name: "param1", param_location: "body"},
        %ApiParameter{
          original_name: "testQueryParam",
          py_name: "test_query_param",
          param_location: "query"
        }
      ]

      kwargs = %{"param1" => "value1", "test_query_param" => "query_value"}

      operation = %{
        "requestBody" => %{
          "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}
        }
      }

      tool = %{tool | operation: operation}

      req = RestApiTool.prepare_request_params(tool, params, kwargs)
      assert req.method == :get
      assert req.url == "https://example.com/test"
      assert req.json == %{"param1" => "value1"}
      assert req.params == %{"testQueryParam" => "query_value"}
    end

    test "extracts embedded query params" do
      endpoint = %OperationEndpoint{
        base_url: "https://example.com",
        path: "/api?embedded_key=embedded_val",
        method: "GET"
      }

      operation = %{"operationId" => "test_op"}
      tool = %RestApiTool{name: "test_tool", endpoint: endpoint, operation: operation}

      params = [
        %ApiParameter{
          original_name: "explicit_key",
          py_name: "explicit_key",
          param_location: "query"
        }
      ]

      kwargs = %{"explicit_key" => "explicit_val"}

      req = RestApiTool.prepare_request_params(tool, params, kwargs)
      assert req.params["embedded_key"] == "embedded_val"
      assert req.params["explicit_key"] == "explicit_val"
      assert not String.contains?(req.url, "?")
      assert req.url == "https://example.com/api"
    end

    test "explicit query param takes precedence" do
      endpoint = %OperationEndpoint{
        base_url: "https://example.com",
        path: "/api?key=embedded",
        method: "GET"
      }

      operation = %{"operationId" => "test_op"}
      tool = %RestApiTool{name: "test_tool", endpoint: endpoint, operation: operation}

      params = [
        %ApiParameter{original_name: "key", py_name: "key", param_location: "query"}
      ]

      kwargs = %{"key" => "explicit"}

      req = RestApiTool.prepare_request_params(tool, params, kwargs)
      assert req.params["key"] == "explicit"
    end

    test "strips fragment only" do
      endpoint = %OperationEndpoint{
        base_url: "https://example.com",
        path: "/api#fragment",
        method: "GET"
      }

      operation = %{"operationId" => "test_op"}
      tool = %RestApiTool{name: "test_tool", endpoint: endpoint, operation: operation}

      req = RestApiTool.prepare_request_params(tool, [], %{})
      assert not String.contains?(req.url, "#")
      assert req.url == "https://example.com/api"
    end
  end

  describe "call" do
    setup do
      endpoint = %OperationEndpoint{base_url: "https://example.com", path: "/test", method: "GET"}
      operation = %{"operationId" => "test_op"}
      tool = %RestApiTool{name: "test_tool", endpoint: endpoint, operation: operation}
      {:ok, tool: tool}
    end

    test "auth pending when auth scheme exists but credential is nil", %{tool: tool} do
      tool = %{tool | auth_scheme: %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}}
      result = RestApiTool.call(tool, %{})
      assert result["pending"] == true
    end
  end
end
