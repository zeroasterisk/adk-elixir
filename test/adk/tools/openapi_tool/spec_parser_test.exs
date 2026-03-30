defmodule ADK.Tool.OpenApiTool.SpecParserTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.OpenApiTool.SpecParser

  defp create_minimal_openapi_spec do
    %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "Minimal API", "version" => "1.0.0"},
      "paths" => %{
        "/test" => %{
          "get" => %{
            "summary" => "Test GET endpoint",
            "operationId" => "testGet",
            "responses" => %{
              "200" => %{
                "description" => "Successful response",
                "content" => %{
                  "application/json" => %{"schema" => %{"type" => "string"}}
                }
              }
            }
          }
        }
      }
    }
  end

  test "parse_minimal_spec" do
    spec = create_minimal_openapi_spec()
    parsed = SpecParser.parse(spec)

    assert length(parsed) == 1
    op = hd(parsed)

    assert op.name == "test_get"
    assert op.endpoint.path == "/test"
    assert op.endpoint.method == "get"
    assert op.return_value.param_schema["type"] == "string"
  end

  test "parse_spec_with_no_operation_id" do
    spec = create_minimal_openapi_spec()
    spec = update_in(spec, ["paths", "/test", "get"], &Map.delete(&1, "operationId"))

    parsed = SpecParser.parse(spec)

    assert length(parsed) == 1
    assert hd(parsed).name == "test_get"
  end

  test "parse_spec_with_multiple_methods" do
    spec = create_minimal_openapi_spec()

    post_method = %{
      "summary" => "Test POST endpoint",
      "operationId" => "testPost",
      "responses" => %{"200" => %{"description" => "Successful response"}}
    }

    spec = put_in(spec, ["paths", "/test", "post"], post_method)

    parsed = SpecParser.parse(spec)

    assert length(parsed) == 2
    names = Enum.map(parsed, & &1.name)
    assert "test_get" in names
    assert "test_post" in names
  end

  test "parse_spec_with_parameters" do
    spec = create_minimal_openapi_spec()

    params = [
      %{"name" => "param1", "in" => "query", "schema" => %{"type" => "string"}},
      %{"name" => "param2", "in" => "header", "schema" => %{"type" => "integer"}}
    ]

    spec = put_in(spec, ["paths", "/test", "get", "parameters"], params)

    parsed = SpecParser.parse(spec)

    op = hd(parsed)
    assert length(op.parameters) == 2
    p1 = Enum.at(op.parameters, 0)
    assert p1.original_name == "param1"
    assert p1.param_location == "query"

    p2 = Enum.at(op.parameters, 1)
    assert p2.original_name == "param2"
    assert p2.param_location == "header"
  end

  test "parse_spec_with_request_body" do
    spec = create_minimal_openapi_spec()

    post_method = %{
      "summary" => "Endpoint with request body",
      "operationId" => "testPostWithBody",
      "requestBody" => %{
        "content" => %{
          "application/json" => %{
            "schema" => %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}}
            }
          }
        }
      },
      "responses" => %{"200" => %{"description" => "OK"}}
    }

    spec = put_in(spec, ["paths", "/test", "post"], post_method)

    parsed = SpecParser.parse(spec)
    post_ops = Enum.filter(parsed, &(&1.endpoint.method == "post"))

    assert length(post_ops) == 1
    op = hd(post_ops)
    assert op.name == "test_post_with_body"
    assert length(op.parameters) == 1
    assert hd(op.parameters).original_name == "name"
  end

  test "parse_spec_with_reference" do
    spec = %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "API with Refs", "version" => "1.0.0"},
      "paths" => %{
        "/test_ref" => %{
          "get" => %{
            "summary" => "Endpoint with ref",
            "operationId" => "testGetRef",
            "responses" => %{
              "200" => %{
                "description" => "Success",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/MySchema"}
                  }
                }
              }
            }
          }
        }
      },
      "components" => %{
        "schemas" => %{
          "MySchema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}}
          }
        }
      }
    }

    parsed = SpecParser.parse(spec)
    assert length(parsed) == 1
    op = hd(parsed)
    assert op.return_value.param_schema["type"] == "object"
    assert get_in(op.return_value.param_schema, ["properties", "name", "type"]) == "string"
  end

  test "parse_spec_with_circular_reference" do
    spec = %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "Circular Ref API", "version" => "1.0.0"},
      "paths" => %{
        "/circular" => %{
          "get" => %{
            "responses" => %{
              "200" => %{
                "description" => "OK",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/A"}
                  }
                }
              }
            }
          }
        }
      },
      "components" => %{
        "schemas" => %{
          "A" => %{
            "type" => "object",
            "properties" => %{"b" => %{"$ref" => "#/components/schemas/B"}}
          },
          "B" => %{
            "type" => "object",
            "properties" => %{"a" => %{"$ref" => "#/components/schemas/A"}}
          }
        }
      }
    }

    parsed = SpecParser.parse(spec)
    assert length(parsed) == 1

    op = hd(parsed)
    assert op.return_value.param_schema["type"] == "object"

    # In circular references, we expect the reference to be resolved up to the cycle point,
    # where the nested object's "$ref" is removed to prevent infinite loops.
    assert Map.has_key?(op.return_value.param_schema["properties"], "b")
  end

  test "parse_no_paths" do
    spec = %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "No Paths API", "version" => "1.0.0"}
    }

    assert SpecParser.parse(spec) == []
  end

  test "parse_empty_path_item" do
    spec = %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "Empty Path Item API", "version" => "1.0.0"},
      "paths" => %{"/empty" => nil}
    }

    assert SpecParser.parse(spec) == []
  end

  test "parse_spec_with_global_auth_scheme" do
    spec = create_minimal_openapi_spec()
    spec = Map.put(spec, "security", [%{"api_key" => []}])

    spec =
      Map.put(spec, "components", %{
        "securitySchemes" => %{
          "api_key" => %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
        }
      })

    parsed = SpecParser.parse(spec)
    op = hd(parsed)

    assert length(parsed) == 1
    assert op.auth_scheme != nil
    assert op.auth_scheme["type"] == "apiKey"
  end

  test "parse_spec_with_local_auth_scheme" do
    spec = create_minimal_openapi_spec()
    spec = put_in(spec, ["paths", "/test", "get", "security"], [%{"local_auth" => []}])

    spec =
      Map.put(spec, "components", %{
        "securitySchemes" => %{
          "local_auth" => %{"type" => "http", "scheme" => "bearer"}
        }
      })

    parsed = SpecParser.parse(spec)
    op = hd(parsed)

    assert op.auth_scheme != nil
    assert op.auth_scheme["type"] == "http"
    assert op.auth_scheme["scheme"] == "bearer"
  end

  test "parse_spec_with_servers" do
    spec = create_minimal_openapi_spec()

    spec =
      Map.put(spec, "servers", [
        %{"url" => "https://api.example.com"},
        %{"url" => "http://localhost:8000"}
      ])

    parsed = SpecParser.parse(spec)
    assert hd(parsed).endpoint.base_url == "https://api.example.com"
  end

  test "parse_spec_with_no_servers" do
    spec = create_minimal_openapi_spec()
    spec = Map.delete(spec, "servers")

    parsed = SpecParser.parse(spec)
    assert hd(parsed).endpoint.base_url == ""
  end

  test "parse_spec_with_description" do
    spec = create_minimal_openapi_spec()
    spec = put_in(spec, ["paths", "/test", "get", "description"], "This is a test description.")

    parsed = SpecParser.parse(spec)
    assert hd(parsed).description == "This is a test description."
  end

  test "parse_invalid_openapi_spec_type" do
    assert_raise ArgumentError, fn -> SpecParser.parse(123) end
    assert_raise ArgumentError, fn -> SpecParser.parse("openapi_spec") end
    assert_raise ArgumentError, fn -> SpecParser.parse([]) end
  end

  test "parse_external_ref_raises_error" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/external" => %{
          "get" => %{
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "$ref" => "external_file.json#/components/schemas/ExternalSchema"
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    assert_raise ArgumentError, fn -> SpecParser.parse(spec) end
  end

  test "parse_spec_with_invalid_type_any" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/test" => %{
          "get" => %{
            "operationId" => "testAnyType",
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{"schema" => %{"type" => "Any"}}
                }
              }
            }
          }
        }
      }
    }

    parsed = SpecParser.parse(spec)
    assert length(parsed) == 1
    assert hd(parsed).name == "test_any_type"
    assert hd(parsed).return_value.param_schema == %{}
  end

  test "sanitize_schema_types_removes_invalid_types" do
    spec = %{
      "components" => %{
        "schemas" => %{
          "InvalidSchema" => %{"type" => "Any", "description" => "Invalid type"},
          "ValidSchema" => %{"type" => "string", "description" => "Valid type"}
        }
      }
    }

    sanitized = SpecParser.sanitize_schema_types(spec)

    assert Map.has_key?(sanitized["components"]["schemas"]["InvalidSchema"], "type") == false
    assert sanitized["components"]["schemas"]["ValidSchema"]["type"] == "string"
  end

  test "parse_spec_with_multiple_paths_deep_refs" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/path1" => %{
          "post" => %{
            "operationId" => "postPath1",
            "requestBody" => %{
              "content" => %{
                "application/json" => %{
                  "schema" => %{"$ref" => "#/components/schemas/Request1"}
                }
              }
            },
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/Response1"}
                  }
                }
              }
            }
          }
        }
      },
      "components" => %{
        "schemas" => %{
          "Request1" => %{
            "type" => "object",
            "properties" => %{"req1_prop1" => %{"$ref" => "#/components/schemas/Level1_1"}}
          },
          "Response1" => %{
            "type" => "object",
            "properties" => %{"res1_prop1" => %{"$ref" => "#/components/schemas/Level1_2"}}
          },
          "Level1_1" => %{
            "type" => "object",
            "properties" => %{"level1_1_prop1" => %{"$ref" => "#/components/schemas/Level2_1"}}
          },
          "Level1_2" => %{
            "type" => "object",
            "properties" => %{"level1_2_prop1" => %{"$ref" => "#/components/schemas/Level2_2"}}
          },
          "Level2_1" => %{
            "type" => "object",
            "properties" => %{"level2_1_prop1" => %{"$ref" => "#/components/schemas/Level3"}}
          },
          "Level2_2" => %{
            "type" => "object",
            "properties" => %{"level2_2_prop1" => %{"type" => "string"}}
          },
          "Level3" => %{"type" => "integer"}
        }
      }
    }

    parsed = SpecParser.parse(spec)
    assert length(parsed) == 1

    op = hd(parsed)
    assert op.name == "post_path1"

    assert length(op.parameters) == 1
    p = hd(op.parameters)
    assert p.original_name == "req1_prop1"

    assert get_in(p.param_schema, [
             "properties",
             "level1_1_prop1",
             "properties",
             "level2_1_prop1",
             "type"
           ]) == "integer"

    assert get_in(op.return_value.param_schema, [
             "properties",
             "res1_prop1",
             "properties",
             "level1_2_prop1",
             "properties",
             "level2_2_prop1",
             "type"
           ]) == "string"
  end

  test "parse_spec_with_duplicate_parameter_names" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/duplicate" => %{
          "post" => %{
            "operationId" => "createWithDuplicate",
            "parameters" => [
              %{"name" => "name", "in" => "query", "schema" => %{"type" => "string"}}
            ],
            "requestBody" => %{
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{"name" => %{"type" => "integer"}}
                  }
                }
              }
            },
            "responses" => %{"200" => %{"description" => "OK"}}
          }
        }
      }
    }

    parsed = SpecParser.parse(spec)
    assert length(parsed) == 1
    op = hd(parsed)
    assert op.name == "create_with_duplicate"
    assert length(op.parameters) == 2

    query_param = Enum.find(op.parameters, &(&1.param_location == "query"))
    body_param = Enum.find(op.parameters, &(&1.param_location == "body"))

    assert query_param.original_name == "name"
    assert query_param.py_name == "name"

    assert body_param.original_name == "name"
    # In Elixir I used `_1` starting suffix, python used `_0`. Parity is fine since it dedupes.
    assert body_param.py_name == "name_1"
  end

  test "parse_spec_with_path_level_parameters" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/test" => %{
          "parameters" => [
            %{"name" => "global_param", "in" => "query", "schema" => %{"type" => "string"}}
          ],
          "get" => %{
            "parameters" => [
              %{"name" => "local_param", "in" => "header", "schema" => %{"type" => "integer"}}
            ],
            "operationId" => "testGet",
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{"schema" => %{"type" => "string"}}
                }
              }
            }
          }
        }
      }
    }

    parsed = SpecParser.parse(spec)
    assert length(parsed) == 1

    op = hd(parsed)
    assert length(op.parameters) == 2

    global_param = Enum.find(op.parameters, &(&1.original_name == "global_param"))
    local_param = Enum.find(op.parameters, &(&1.original_name == "local_param"))

    assert global_param.param_location == "query"
    assert local_param.param_location == "header"
  end

  test "parse_spec_with_nested_invalid_types" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/test" => %{
          "post" => %{
            "operationId" => "testNestedInvalid",
            "requestBody" => %{
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "valid_prop" => %{"type" => "string"},
                      "invalid_prop" => %{"type" => "Unknown"},
                      "nested_obj" => %{
                        "type" => "object",
                        "properties" => %{
                          "deeply_invalid" => %{"type" => "CustomType"}
                        }
                      }
                    }
                  }
                }
              }
            },
            "responses" => %{"200" => %{"description" => "OK"}}
          }
        }
      }
    }

    parsed = SpecParser.parse(spec)
    assert length(parsed) == 1
    op = hd(parsed)

    param_names = Enum.map(op.parameters, & &1.original_name)
    assert "valid_prop" in param_names
    assert "invalid_prop" in param_names
    assert "nested_obj" in param_names
  end

  test "parse_spec_with_type_list_containing_invalid" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/test" => %{
          "get" => %{
            "operationId" => "testTypeList",
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"type" => ["string", "Any", "null"]}
                  }
                }
              }
            }
          }
        }
      }
    }

    parsed = SpecParser.parse(spec)
    assert length(parsed) == 1
    assert hd(parsed).return_value.param_schema["type"] == ["string", "null"]
  end

  test "sanitize_schema_types_does_not_touch_security_schemes" do
    spec = %{
      "components" => %{
        "schemas" => %{"InvalidSchema" => %{"type" => "Any"}},
        "securitySchemes" => %{
          "api_key" => %{
            "type" => "apiKey",
            "in" => "header",
            "name" => "X-API-Key"
          }
        }
      }
    }

    sanitized = SpecParser.sanitize_schema_types(spec)

    assert Map.has_key?(sanitized["components"]["schemas"]["InvalidSchema"], "type") == false
    assert sanitized["components"]["securitySchemes"]["api_key"]["type"] == "apiKey"
  end

  test "sanitize_schema_types_filters_type_lists" do
    spec = %{"schema" => %{"type" => ["string", "Any", "null", "Unknown"]}}
    sanitized = SpecParser.sanitize_schema_types(spec)
    assert sanitized["schema"]["type"] == ["string", "null"]
  end

  test "sanitize_schema_types_removes_all_invalid_list" do
    spec = %{"schema" => %{"type" => ["Any", "Unknown", "Custom"]}}
    sanitized = SpecParser.sanitize_schema_types(spec)
    assert Map.has_key?(sanitized["schema"], "type") == false
  end
end
