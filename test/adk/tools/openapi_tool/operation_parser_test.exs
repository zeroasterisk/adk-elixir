defmodule ADK.Tool.OpenApiTool.OperationParserTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.OpenApiTool.SpecParser

  defp create_operation_spec(operation_overrides) do
    %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "Operation API", "version" => "1.0.0"},
      "paths" => %{
        "/test" => %{
          "post" => Map.merge(%{
            "operationId" => "test_operation",
            "responses" => %{
              "200" => %{
                "description" => "Success",
                "content" => %{
                  "application/json" => %{"schema" => %{"type" => "string"}}
                }
              }
            }
          }, operation_overrides)
        }
      }
    }
  end

  test "process_request_body_array" do
    spec = create_operation_spec(%{
      "requestBody" => %{
        "content" => %{
          "application/json" => %{
            "schema" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "item_prop1" => %{"type" => "string", "description" => "Item Property 1"},
                  "item_prop2" => %{"type" => "integer", "description" => "Item Property 2"}
                }
              }
            }
          }
        }
      }
    })

    [parsed_op] = SpecParser.parse(spec)
    assert length(parsed_op.parameters) == 1
    param = hd(parsed_op.parameters)

    assert param.original_name == "array"
    assert param.param_location == "body"
    assert param.param_schema["type"] == "array"
    assert param.param_schema["items"]["type"] == "object"
    assert Map.has_key?(param.param_schema["items"]["properties"], "item_prop1")
    assert Map.has_key?(param.param_schema["items"]["properties"], "item_prop2")
    assert param.param_schema["items"]["properties"]["item_prop1"]["description"] == "Item Property 1"
  end

  test "process_request_body_no_name" do
    spec = create_operation_spec(%{
      "requestBody" => %{
        "content" => %{
          "application/json" => %{
            "schema" => %{"type" => "string"}
          }
        }
      }
    })

    [parsed_op] = SpecParser.parse(spec)
    assert length(parsed_op.parameters) == 1
    param = hd(parsed_op.parameters)

    # Elixir implementation sets original_name to "" and py_name to "body" through deduping
    assert param.original_name == ""
    assert param.py_name == "body"
    assert param.param_location == "body"
  end

  test "process_request_body_one_of_schema_assigns_name" do
    spec = create_operation_spec(%{
      "operationId" => "one_of_request",
      "requestBody" => %{
        "content" => %{
          "application/json" => %{
            "schema" => %{
              "oneOf" => [
                %{
                  "type" => "object",
                  "properties" => %{
                    "type" => %{"type" => "string"},
                    "stage" => %{"type" => "string"}
                  }
                }
              ],
              "discriminator" => %{"propertyName" => "type"}
            }
          }
        }
      }
    })

    [parsed_op] = SpecParser.parse(spec)
    assert length(parsed_op.parameters) == 1
    param = hd(parsed_op.parameters)

    assert param.original_name == "body"
    assert param.py_name == "body"
    assert param.param_location == "body"
    assert Map.has_key?(param.param_schema, "oneOf")
  end

  test "process_request_body_empty_object" do
    spec = create_operation_spec(%{
      "requestBody" => %{
        "content" => %{
          "application/json" => %{
            "schema" => %{"type" => "object"}
          }
        }
      }
    })

    [parsed_op] = SpecParser.parse(spec)
    assert parsed_op.parameters == []
  end

  test "process_return_value_no_2xx" do
    spec = create_operation_spec(%{
      "responses" => %{
        "400" => %{"description" => "Client Error"}
      }
    })

    [parsed_op] = SpecParser.parse(spec)
    # When no 2xx response exists, return schema should be empty map
    assert parsed_op.return_value.param_schema == %{}
  end

  test "process_return_value_multiple_2xx" do
    spec = create_operation_spec(%{
      "responses" => %{
        "201" => %{
          "description" => "Success 201",
          "content" => %{"application/json" => %{"schema" => %{"type" => "integer"}}}
        },
        "202" => %{
          "description" => "Success 202",
          "content" => %{"text/plain" => %{"schema" => %{"type" => "string"}}}
        },
        "200" => %{
          "description" => "Success 200",
          "content" => %{"application/pdf" => %{"schema" => %{"type" => "boolean"}}}
        },
        "400" => %{
          "description" => "Failure",
          "content" => %{"application/xml" => %{"schema" => %{"type" => "object"}}}
        }
      }
    })

    [parsed_op] = SpecParser.parse(spec)
    # Should take the 200 response since it's the smallest response code
    assert parsed_op.return_value.param_schema["type"] == "boolean"
  end

  test "process_return_value_no_content" do
    spec = create_operation_spec(%{
      "responses" => %{
        "200" => %{"description" => "Success", "content" => %{}}
      }
    })

    [parsed_op] = SpecParser.parse(spec)
    assert parsed_op.return_value.param_schema == %{}
  end

  test "process_return_value_no_schema" do
    spec = create_operation_spec(%{
      "responses" => %{
        "200" => %{
          "description" => "Success",
          "content" => %{"application/json" => %{}} # no schema key
        }
      }
    })

    [parsed_op] = SpecParser.parse(spec)
    assert parsed_op.return_value.param_schema == %{}
  end

  test "get_auth_scheme_name_no_security" do
    spec = create_operation_spec(%{})
    # By default our minimal spec has no security
    [parsed_op] = SpecParser.parse(spec)
    assert parsed_op.auth_scheme == nil
  end
end
