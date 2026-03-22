defmodule ADK.Tool.GoogleApiTool.GoogleApiToOpenApiConverter do
  @moduledoc """
  Converts Google API Discovery documents to OpenAPI v3 format.
  """

  @doc """
  Convert the Google API spec to OpenAPI v3 format.

  ## Parameters
    - `api_spec`: The Google API discovery document map
    - `api_name`: The name of the API
    - `api_version`: The version of the API
  """
  def convert(api_spec, api_name \\ "api", api_version \\ "v1") do
    openapi_spec = %{
      "openapi" => "3.0.0",
      "info" => convert_info(api_spec, api_name, api_version),
      "servers" => convert_servers(api_spec, api_name, api_version),
      "paths" => %{},
      "components" => %{
        "schemas" => convert_schemas(api_spec),
        "securitySchemes" => convert_security_schemes(api_spec)
      }
    }

    # Convert methods recursively
    openapi_spec = convert_resources(openapi_spec, api_spec |> Map.get("resources", %{}), "")
    openapi_spec = convert_methods(openapi_spec, api_spec |> Map.get("methods", %{}), "/")

    # Add global security requirements
    openapi_spec = Map.put(openapi_spec, "security", global_security(api_spec))

    openapi_spec
  end

  defp convert_info(api_spec, api_name, api_version) do
    info = %{
      "title" => Map.get(api_spec, "title", "#{api_name} API"),
      "description" => Map.get(api_spec, "description", ""),
      "version" => Map.get(api_spec, "version", api_version),
      "contact" => %{},
      "termsOfService" => Map.get(api_spec, "documentationLink", "")
    }

    info
  end

  defp convert_servers(api_spec, api_name, api_version) do
    base_url = Map.get(api_spec, "rootUrl", "") <> Map.get(api_spec, "servicePath", "")
    base_url = String.trim_trailing(base_url, "/")
    [%{"url" => base_url, "description" => "#{api_name} #{api_version} API"}]
  end

  defp convert_security_schemes(api_spec) do
    auth = Map.get(api_spec, "auth", %{})
    oauth2 = Map.get(auth, "oauth2", %{})
    scopes = Map.get(oauth2, "scopes", %{})

    formatted_scopes =
      scopes
      |> Enum.map(fn {scope, info} -> {scope, Map.get(info, "description", "")} end)
      |> Map.new()

    schemes = %{
      "apiKey" => %{
        "type" => "apiKey",
        "in" => "query",
        "name" => "key",
        "description" => "API key for accessing this API"
      }
    }

    schemes =
      if map_size(formatted_scopes) > 0 do
        Map.put(schemes, "oauth2", %{
          "type" => "oauth2",
          "description" => "OAuth 2.0 authentication",
          "flows" => %{
            "authorizationCode" => %{
              "authorizationUrl" => "https://accounts.google.com/o/oauth2/auth",
              "tokenUrl" => "https://oauth2.googleapis.com/token",
              "scopes" => formatted_scopes
            }
          }
        })
      else
        schemes
      end

    schemes
  end

  defp global_security(api_spec) do
    auth = Map.get(api_spec, "auth", %{})
    oauth2 = Map.get(auth, "oauth2", %{})
    scopes = Map.get(oauth2, "scopes", %{}) |> Map.keys()

    security = [%{"apiKey" => []}]

    if length(scopes) > 0 do
      [%{"oauth2" => scopes} | security]
    else
      security
    end
  end

  defp convert_schemas(api_spec) do
    schemas = Map.get(api_spec, "schemas", %{})
    Enum.reduce(schemas, %{}, fn {name, def}, acc ->
      Map.put(acc, name, convert_schema_object(def))
    end)
  end

  defp convert_schema_object(schema_def) do
    result = %{}

    result =
      case Map.get(schema_def, "type") do
        "object" ->
          r = Map.put(result, "type", "object")
          
          properties = Map.get(schema_def, "properties", %{})
          r =
            if map_size(properties) > 0 do
              converted_props =
                Enum.reduce(properties, %{}, fn {name, pdef}, acc ->
                  Map.put(acc, name, convert_schema_object(pdef))
                end)
              Map.put(r, "properties", converted_props)
            else
              r
            end

          required_fields =
            Enum.filter(properties, fn {_k, v} -> Map.get(v, "required", false) end)
            |> Enum.map(fn {k, _v} -> k end)

          if required_fields != [] do
            Map.put(r, "required", required_fields)
          else
            r
          end

        "array" ->
          r = Map.put(result, "type", "array")
          items = Map.get(schema_def, "items")
          if items do
            Map.put(r, "items", convert_schema_object(items))
          else
            r
          end

        "any" ->
          Map.put(result, "oneOf", [
            %{"type" => "object"},
            %{"type" => "array"},
            %{"type" => "string"},
            %{"type" => "number"},
            %{"type" => "boolean"},
            %{"type" => "null"}
          ])

        nil -> result
        
        type ->
          Map.put(result, "type", type)
      end

    # Handle refs
    ref = Map.get(schema_def, "$ref")
    result =
      if ref do
        ref_formatted =
          if String.starts_with?(ref, "#") do
            String.replace(ref, "#", "#/components/schemas/")
          else
            "#/components/schemas/" <> ref
          end
        Map.put(result, "$ref", ref_formatted)
      else
        result
      end

    # Handle other standard attributes
    result = put_if_present(result, schema_def, "format")
    result = put_if_present(result, schema_def, "enum")
    result = put_if_present(result, schema_def, "description")
    result = put_if_present(result, schema_def, "pattern")
    result = put_if_present(result, schema_def, "default")

    result
  end

  defp put_if_present(target, source, key) do
    case Map.get(source, key) do
      nil -> target
      val -> Map.put(target, key, val)
    end
  end

  defp convert_resources(openapi_spec, resources, parent_path) do
    Enum.reduce(resources, openapi_spec, fn {resource_name, resource_data}, spec_acc ->
      resource_path = "#{parent_path}/#{resource_name}"
      methods = Map.get(resource_data, "methods", %{})
      spec_acc = convert_methods(spec_acc, methods, resource_path)

      nested_resources = Map.get(resource_data, "resources", %{})
      convert_resources(spec_acc, nested_resources, resource_path)
    end)
  end

  @doc false
  def convert_methods(openapi_spec, methods, _resource_path) do
    Enum.reduce(methods, openapi_spec, fn {_method_name, method_data}, spec_acc ->
      http_method = Map.get(method_data, "httpMethod", "GET") |> String.downcase()

      # Google prefers flatPath, defaults to path
      rest_path = Map.get(method_data, "flatPath", Map.get(method_data, "path", "/"))
      rest_path = if String.starts_with?(rest_path, "/"), do: rest_path, else: "/" <> rest_path

      path_params = extract_path_parameters(rest_path)
      
      paths = Map.get(spec_acc, "paths", %{})
      path_entry = Map.get(paths, rest_path, %{})
      
      operation = convert_operation(method_data, path_params)
      path_entry = Map.put(path_entry, http_method, operation)
      
      Map.put(spec_acc, "paths", Map.put(paths, rest_path, path_entry))
    end)
  end

  defp extract_path_parameters(path) do
    path
    |> String.split("/")
    |> Enum.filter(fn segment -> String.starts_with?(segment, "{") and String.ends_with?(segment, "}") end)
    |> Enum.map(fn segment -> String.slice(segment, 1..-2//1) end)
  end

  defp convert_operation(method_data, path_params) do
    operation = %{
      "operationId" => Map.get(method_data, "id", ""),
      "summary" => Map.get(method_data, "description", ""),
      "description" => Map.get(method_data, "description", ""),
      "parameters" => [],
      "responses" => %{
        "200" => %{"description" => "Successful operation"},
        "400" => %{"description" => "Bad request"},
        "401" => %{"description" => "Unauthorized"},
        "403" => %{"description" => "Forbidden"},
        "404" => %{"description" => "Not found"},
        "500" => %{"description" => "Server error"}
      }
    }

    params = Enum.map(path_params, fn param_name ->
      %{
        "name" => param_name,
        "in" => "path",
        "required" => true,
        "schema" => %{"type" => "string"}
      }
    end)

    query_params = Map.get(method_data, "parameters", %{})
    params = Enum.reduce(query_params, params, fn {param_name, param_data}, acc ->
      if param_name in path_params do
        acc
      else
        param = %{
          "name" => param_name,
          "in" => Map.get(param_data, "location", "query"),
          "description" => Map.get(param_data, "description", ""),
          "required" => Map.get(param_data, "required", false),
          "schema" => convert_parameter_schema(param_data)
        }
        acc ++ [param]
      end
    end)

    operation = Map.put(operation, "parameters", params)

    operation =
      if Map.has_key?(method_data, "request") do
        request_ref = Map.get(method_data["request"], "$ref", "")
        if request_ref != "" do
          openapi_ref =
            if String.starts_with?(request_ref, "#") do
              String.replace(request_ref, "#", "#/components/schemas/")
            else
              "#/components/schemas/" <> request_ref
            end

          Map.put(operation, "requestBody", %{
            "description" => "Request body",
            "content" => %{"application/json" => %{"schema" => %{"$ref" => openapi_ref}}},
            "required" => true
          })
        else
          operation
        end
      else
        operation
      end

    operation =
      if Map.has_key?(method_data, "response") do
        response_ref = Map.get(method_data["response"], "$ref", "")
        if response_ref != "" do
          openapi_ref =
            if String.starts_with?(response_ref, "#") do
              String.replace(response_ref, "#", "#/components/schemas/")
            else
              "#/components/schemas/" <> response_ref
            end

          responses = operation["responses"]
          responses_200 = Map.put(responses["200"], "content", %{
            "application/json" => %{"schema" => %{"$ref" => openapi_ref}}
          })

          Map.put(operation, "responses", Map.put(responses, "200", responses_200))
        else
          operation
        end
      else
        operation
      end

    scopes = Map.get(method_data, "scopes", [])
    if length(scopes) > 0 do
      Map.put(operation, "security", [%{"oauth2" => scopes}])
    else
      operation
    end
  end

  defp convert_parameter_schema(param_data) do
    schema = %{}
    
    schema = Map.put(schema, "type", Map.get(param_data, "type", "string"))
    schema = put_if_present(schema, param_data, "enum")
    schema = put_if_present(schema, param_data, "format")
    schema = put_if_present(schema, param_data, "default")
    schema = put_if_present(schema, param_data, "pattern")

    schema
  end
end
