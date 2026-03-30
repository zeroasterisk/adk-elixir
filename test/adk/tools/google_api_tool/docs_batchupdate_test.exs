defmodule ADK.Tool.GoogleApiTool.DocsBatchUpdateTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.GoogleApiTool.GoogleApiToOpenApiConverter

  defp docs_api_spec do
    %{
      "kind" => "discovery#restDescription",
      "id" => "docs:v1",
      "name" => "docs",
      "version" => "v1",
      "title" => "Google Docs API",
      "description" => "Reads and writes Google Docs documents.",
      "documentationLink" => "https://developers.google.com/docs/",
      "protocol" => "rest",
      "rootUrl" => "https://docs.googleapis.com/",
      "servicePath" => "",
      "auth" => %{
        "oauth2" => %{
          "scopes" => %{
            "https://www.googleapis.com/auth/documents" => %{
              "description" => "See, edit, create, and delete all of your Google Docs documents"
            },
            "https://www.googleapis.com/auth/documents.readonly" => %{
              "description" => "View your Google Docs documents"
            },
            "https://www.googleapis.com/auth/drive" => %{
              "description" => "See, edit, create, and delete all of your Google Drive files"
            },
            "https://www.googleapis.com/auth/drive.file" => %{
              "description" =>
                "View and manage Google Drive files and folders that you have opened or created with this app"
            }
          }
        }
      },
      "schemas" => %{
        "Document" => %{
          "type" => "object",
          "description" => "A Google Docs document",
          "properties" => %{
            "documentId" => %{"type" => "string", "description" => "The ID of the document"},
            "title" => %{"type" => "string", "description" => "The title of the document"},
            "body" => %{"$ref" => "Body", "description" => "The document body"},
            "revisionId" => %{
              "type" => "string",
              "description" => "The revision ID of the document"
            }
          }
        },
        "Body" => %{
          "type" => "object",
          "description" => "The document body",
          "properties" => %{
            "content" => %{
              "type" => "array",
              "description" => "The content of the body",
              "items" => %{"$ref" => "StructuralElement"}
            }
          }
        },
        "StructuralElement" => %{
          "type" => "object",
          "description" => "A structural element of a document",
          "properties" => %{
            "startIndex" => %{"type" => "integer", "description" => "The zero-based start index"},
            "endIndex" => %{"type" => "integer", "description" => "The zero-based end index"}
          }
        },
        "BatchUpdateDocumentRequest" => %{
          "type" => "object",
          "description" => "Request to batch update a document",
          "properties" => %{
            "requests" => %{
              "type" => "array",
              "description" => "A list of updates to apply to the document",
              "items" => %{"$ref" => "Request"}
            },
            "writeControl" => %{
              "$ref" => "WriteControl",
              "description" => "Provides control over how write requests are executed"
            }
          }
        },
        "Request" => %{
          "type" => "object",
          "description" => "A single kind of update to apply to a document",
          "properties" => %{
            "insertText" => %{"$ref" => "InsertTextRequest"},
            "updateTextStyle" => %{"$ref" => "UpdateTextStyleRequest"},
            "replaceAllText" => %{"$ref" => "ReplaceAllTextRequest"}
          }
        },
        "InsertTextRequest" => %{
          "type" => "object",
          "description" => "Inserts text into the document",
          "properties" => %{
            "location" => %{"$ref" => "Location", "description" => "The location to insert text"},
            "text" => %{"type" => "string", "description" => "The text to insert"}
          }
        },
        "UpdateTextStyleRequest" => %{
          "type" => "object",
          "description" => "Updates the text style of the specified range",
          "properties" => %{
            "range" => %{"$ref" => "Range", "description" => "The range to update"},
            "textStyle" => %{"$ref" => "TextStyle", "description" => "The text style to apply"},
            "fields" => %{
              "type" => "string",
              "description" => "The fields that should be updated"
            }
          }
        },
        "ReplaceAllTextRequest" => %{
          "type" => "object",
          "description" => "Replaces all instances of text matching criteria",
          "properties" => %{
            "containsText" => %{"$ref" => "SubstringMatchCriteria"},
            "replaceText" => %{
              "type" => "string",
              "description" => "The text that will replace the matched text"
            }
          }
        },
        "Location" => %{
          "type" => "object",
          "description" => "A particular location in the document",
          "properties" => %{
            "index" => %{"type" => "integer", "description" => "The zero-based index"},
            "tabId" => %{"type" => "string", "description" => "The tab the location is in"}
          }
        },
        "Range" => %{
          "type" => "object",
          "description" => "Specifies a contiguous range of text",
          "properties" => %{
            "startIndex" => %{"type" => "integer", "description" => "The zero-based start index"},
            "endIndex" => %{"type" => "integer", "description" => "The zero-based end index"}
          }
        },
        "TextStyle" => %{
          "type" => "object",
          "description" => "Represents the styling that can be applied to text",
          "properties" => %{
            "bold" => %{"type" => "boolean", "description" => "Whether or not the text is bold"},
            "italic" => %{
              "type" => "boolean",
              "description" => "Whether or not the text is italic"
            },
            "fontSize" => %{"$ref" => "Dimension", "description" => "The size of the text's font"}
          }
        },
        "SubstringMatchCriteria" => %{
          "type" => "object",
          "description" => "A criteria that matches a specific string of text in the document",
          "properties" => %{
            "text" => %{"type" => "string", "description" => "The text to search for"},
            "matchCase" => %{
              "type" => "boolean",
              "description" => "Indicates whether the search should respect case"
            }
          }
        },
        "WriteControl" => %{
          "type" => "object",
          "description" => "Provides control over how write requests are executed",
          "properties" => %{
            "requiredRevisionId" => %{
              "type" => "string",
              "description" => "The required revision ID"
            },
            "targetRevisionId" => %{"type" => "string", "description" => "The target revision ID"}
          }
        },
        "BatchUpdateDocumentResponse" => %{
          "type" => "object",
          "description" => "Response from a BatchUpdateDocument request",
          "properties" => %{
            "documentId" => %{"type" => "string", "description" => "The ID of the document"},
            "replies" => %{
              "type" => "array",
              "description" => "The reply of the updates",
              "items" => %{"$ref" => "Response"}
            },
            "writeControl" => %{
              "$ref" => "WriteControl",
              "description" => "The updated write control"
            }
          }
        },
        "Response" => %{
          "type" => "object",
          "description" => "A single response from an update",
          "properties" => %{
            "replaceAllText" => %{"$ref" => "ReplaceAllTextResponse"}
          }
        },
        "ReplaceAllTextResponse" => %{
          "type" => "object",
          "description" => "The result of replacing text",
          "properties" => %{
            "occurrencesChanged" => %{
              "type" => "integer",
              "description" => "The number of occurrences changed"
            }
          }
        }
      },
      "resources" => %{
        "documents" => %{
          "methods" => %{
            "get" => %{
              "id" => "docs.documents.get",
              "path" => "v1/documents/{documentId}",
              "flatPath" => "v1/documents/{documentId}",
              "httpMethod" => "GET",
              "description" => "Gets the latest version of the specified document.",
              "parameters" => %{
                "documentId" => %{
                  "type" => "string",
                  "description" => "The ID of the document to retrieve",
                  "required" => true,
                  "location" => "path"
                }
              },
              "response" => %{"$ref" => "Document"},
              "scopes" => [
                "https://www.googleapis.com/auth/documents",
                "https://www.googleapis.com/auth/documents.readonly",
                "https://www.googleapis.com/auth/drive",
                "https://www.googleapis.com/auth/drive.file"
              ]
            },
            "create" => %{
              "id" => "docs.documents.create",
              "path" => "v1/documents",
              "httpMethod" => "POST",
              "description" => "Creates a blank document using the title given in the request.",
              "request" => %{"$ref" => "Document"},
              "response" => %{"$ref" => "Document"},
              "scopes" => [
                "https://www.googleapis.com/auth/documents",
                "https://www.googleapis.com/auth/drive",
                "https://www.googleapis.com/auth/drive.file"
              ]
            },
            "batchUpdate" => %{
              "id" => "docs.documents.batchUpdate",
              "path" => "v1/documents/{documentId}:batchUpdate",
              "flatPath" => "v1/documents/{documentId}:batchUpdate",
              "httpMethod" => "POST",
              "description" => "Applies one or more updates to the document.",
              "parameters" => %{
                "documentId" => %{
                  "type" => "string",
                  "description" => "The ID of the document to update",
                  "required" => true,
                  "location" => "path"
                }
              },
              "request" => %{"$ref" => "BatchUpdateDocumentRequest"},
              "response" => %{"$ref" => "BatchUpdateDocumentResponse"},
              "scopes" => [
                "https://www.googleapis.com/auth/documents",
                "https://www.googleapis.com/auth/drive",
                "https://www.googleapis.com/auth/drive.file"
              ]
            }
          }
        }
      }
    }
  end

  test "batch_update_method_conversion" do
    methods = docs_api_spec()["resources"]["documents"]["methods"]

    # In Elixir implementation, we pass the spec to a generic convert_methods
    openapi_spec = %{"paths" => %{}}

    openapi_spec =
      GoogleApiToOpenApiConverter.convert_methods(openapi_spec, methods, "/v1/documents")

    paths = openapi_spec["paths"]

    assert Map.has_key?(paths, "/v1/documents/{documentId}:batchUpdate")
    batch_update_method = paths["/v1/documents/{documentId}:batchUpdate"]["post"]

    assert batch_update_method["operationId"] == "docs.documents.batchUpdate"
    assert batch_update_method["summary"] == "Applies one or more updates to the document."

    params = batch_update_method["parameters"]
    param_names = Enum.map(params, & &1["name"])
    assert "documentId" in param_names

    assert Map.has_key?(batch_update_method, "requestBody")
    request_body = batch_update_method["requestBody"]
    assert request_body["required"] == true
    request_schema = request_body["content"]["application/json"]["schema"]
    assert request_schema["$ref"] == "#/components/schemas/BatchUpdateDocumentRequest"

    assert Map.has_key?(batch_update_method, "responses")

    response_schema =
      batch_update_method["responses"]["200"]["content"]["application/json"]["schema"]

    assert response_schema["$ref"] == "#/components/schemas/BatchUpdateDocumentResponse"

    assert Map.has_key?(batch_update_method, "security")
  end

  test "batch_update_request_schema_conversion" do
    openapi_spec = GoogleApiToOpenApiConverter.convert(docs_api_spec())
    schemas = openapi_spec["components"]["schemas"]

    assert Map.has_key?(schemas, "BatchUpdateDocumentRequest")
    batch_request_schema = schemas["BatchUpdateDocumentRequest"]

    assert batch_request_schema["type"] == "object"
    assert Map.has_key?(batch_request_schema, "properties")
    assert Map.has_key?(batch_request_schema["properties"], "requests")
    assert Map.has_key?(batch_request_schema["properties"], "writeControl")

    requests_prop = batch_request_schema["properties"]["requests"]
    assert requests_prop["type"] == "array"
    assert requests_prop["items"]["$ref"] == "#/components/schemas/Request"
  end

  test "batch_update_response_schema_conversion" do
    openapi_spec = GoogleApiToOpenApiConverter.convert(docs_api_spec())
    schemas = openapi_spec["components"]["schemas"]

    assert Map.has_key?(schemas, "BatchUpdateDocumentResponse")
    batch_response_schema = schemas["BatchUpdateDocumentResponse"]

    assert batch_response_schema["type"] == "object"
    assert Map.has_key?(batch_response_schema, "properties")
    assert Map.has_key?(batch_response_schema["properties"], "documentId")
    assert Map.has_key?(batch_response_schema["properties"], "replies")
    assert Map.has_key?(batch_response_schema["properties"], "writeControl")

    replies_prop = batch_response_schema["properties"]["replies"]
    assert replies_prop["type"] == "array"
    assert replies_prop["items"]["$ref"] == "#/components/schemas/Response"
  end

  test "batch_update_request_types_conversion" do
    openapi_spec = GoogleApiToOpenApiConverter.convert(docs_api_spec())
    schemas = openapi_spec["components"]["schemas"]

    assert Map.has_key?(schemas, "Request")
    request_schema = schemas["Request"]
    assert Map.has_key?(request_schema, "properties")

    assert Map.has_key?(request_schema["properties"], "insertText")
    assert Map.has_key?(request_schema["properties"], "updateTextStyle")
    assert Map.has_key?(request_schema["properties"], "replaceAllText")

    assert Map.has_key?(schemas, "InsertTextRequest")
    insert_text_schema = schemas["InsertTextRequest"]
    assert Map.has_key?(insert_text_schema["properties"], "location")
    assert Map.has_key?(insert_text_schema["properties"], "text")

    assert Map.has_key?(schemas, "UpdateTextStyleRequest")
    update_style_schema = schemas["UpdateTextStyleRequest"]
    assert Map.has_key?(update_style_schema["properties"], "range")
    assert Map.has_key?(update_style_schema["properties"], "textStyle")
    assert Map.has_key?(update_style_schema["properties"], "fields")
  end

  test "convert_methods" do
    methods = docs_api_spec()["resources"]["documents"]["methods"]

    openapi_spec = %{"paths" => %{}}

    openapi_spec =
      GoogleApiToOpenApiConverter.convert_methods(openapi_spec, methods, "/v1/documents")

    paths = openapi_spec["paths"]

    assert Map.has_key?(paths, "/v1/documents/{documentId}")
    get_method = paths["/v1/documents/{documentId}"]["get"]
    assert get_method["operationId"] == "docs.documents.get"

    params = get_method["parameters"]
    param_names = Enum.map(params, & &1["name"])
    assert "documentId" in param_names

    assert Map.has_key?(paths, "/v1/documents")
    post_method = paths["/v1/documents"]["post"]
    assert post_method["operationId"] == "docs.documents.create"

    assert Map.has_key?(post_method, "requestBody")

    assert post_method["requestBody"]["content"]["application/json"]["schema"]["$ref"] ==
             "#/components/schemas/Document"

    assert post_method["responses"]["200"]["content"]["application/json"]["schema"]["$ref"] ==
             "#/components/schemas/Document"

    assert Map.has_key?(paths, "/v1/documents/{documentId}:batchUpdate")
    batch_update_method = paths["/v1/documents/{documentId}:batchUpdate"]["post"]
    assert batch_update_method["operationId"] == "docs.documents.batchUpdate"
  end

  test "complete_docs_api_conversion" do
    result = GoogleApiToOpenApiConverter.convert(docs_api_spec())

    assert result["openapi"] == "3.0.0"
    assert Map.has_key?(result, "info")
    assert Map.has_key?(result, "servers")
    assert Map.has_key?(result, "paths")
    assert Map.has_key?(result, "components")

    paths = result["paths"]
    assert Map.has_key?(paths, "/v1/documents/{documentId}")
    assert Map.has_key?(paths["/v1/documents/{documentId}"], "get")

    assert Map.has_key?(paths, "/v1/documents/{documentId}:batchUpdate")
    assert Map.has_key?(paths["/v1/documents/{documentId}:batchUpdate"], "post")

    get_document = paths["/v1/documents/{documentId}"]["get"]
    assert get_document["operationId"] == "docs.documents.get"
    assert Map.has_key?(get_document, "parameters")

    batch_update = paths["/v1/documents/{documentId}:batchUpdate"]["post"]
    assert batch_update["operationId"] == "docs.documents.batchUpdate"

    assert Map.has_key?(batch_update, "requestBody")
    request_schema = batch_update["requestBody"]["content"]["application/json"]["schema"]
    assert request_schema["$ref"] == "#/components/schemas/BatchUpdateDocumentRequest"

    assert Map.has_key?(batch_update, "responses")
    response_schema = batch_update["responses"]["200"]["content"]["application/json"]["schema"]
    assert response_schema["$ref"] == "#/components/schemas/BatchUpdateDocumentResponse"

    schemas = result["components"]["schemas"]
    assert Map.has_key?(schemas, "Document")
    assert Map.has_key?(schemas, "BatchUpdateDocumentRequest")
    assert Map.has_key?(schemas, "BatchUpdateDocumentResponse")
    assert Map.has_key?(schemas, "InsertTextRequest")
    assert Map.has_key?(schemas, "UpdateTextStyleRequest")
    assert Map.has_key?(schemas, "ReplaceAllTextRequest")
  end

  test "batch_update_example_request_structure" do
    result = GoogleApiToOpenApiConverter.convert(docs_api_spec())
    schemas = result["components"]["schemas"]

    assert Map.has_key?(schemas, "BatchUpdateDocumentRequest")
    assert Map.has_key?(schemas, "Request")
    assert Map.has_key?(schemas, "InsertTextRequest")
    assert Map.has_key?(schemas, "UpdateTextStyleRequest")
    assert Map.has_key?(schemas, "Location")
    assert Map.has_key?(schemas, "Range")
    assert Map.has_key?(schemas, "TextStyle")
    assert Map.has_key?(schemas, "WriteControl")

    location_schema = schemas["Location"]
    assert Map.has_key?(location_schema["properties"], "index")
    assert location_schema["properties"]["index"]["type"] == "integer"

    range_schema = schemas["Range"]
    assert Map.has_key?(range_schema["properties"], "startIndex")
    assert Map.has_key?(range_schema["properties"], "endIndex")

    text_style_schema = schemas["TextStyle"]
    assert Map.has_key?(text_style_schema["properties"], "bold")
    assert text_style_schema["properties"]["bold"]["type"] == "boolean"
  end

  test "integration_docs_api" do
    openapi_spec = GoogleApiToOpenApiConverter.convert(docs_api_spec())

    assert openapi_spec["info"]["title"] == "Google Docs API"
    assert hd(openapi_spec["servers"])["url"] == "https://docs.googleapis.com"

    security_schemes = openapi_spec["components"]["securitySchemes"]
    assert Map.has_key?(security_schemes, "oauth2")
    assert Map.has_key?(security_schemes, "apiKey")

    schemas = openapi_spec["components"]["schemas"]
    assert Map.has_key?(schemas, "Document")
    assert Map.has_key?(schemas, "BatchUpdateDocumentRequest")
    assert Map.has_key?(schemas, "BatchUpdateDocumentResponse")
    assert Map.has_key?(schemas, "InsertTextRequest")
    assert Map.has_key?(schemas, "UpdateTextStyleRequest")
    assert Map.has_key?(schemas, "ReplaceAllTextRequest")

    paths = openapi_spec["paths"]
    assert Map.has_key?(paths, "/v1/documents/{documentId}")
    assert Map.has_key?(paths, "/v1/documents")
    assert Map.has_key?(paths, "/v1/documents/{documentId}:batchUpdate")

    get_document = paths["/v1/documents/{documentId}"]["get"]
    assert get_document["operationId"] == "docs.documents.get"

    batch_update = paths["/v1/documents/{documentId}:batchUpdate"]["post"]
    assert batch_update["operationId"] == "docs.documents.batchUpdate"

    param_dict = Map.new(get_document["parameters"], fn p -> {p["name"], p} end)
    assert Map.has_key?(param_dict, "documentId")
    document_id = param_dict["documentId"]
    assert document_id["required"] == true
    assert document_id["schema"]["type"] == "string"
  end
end
