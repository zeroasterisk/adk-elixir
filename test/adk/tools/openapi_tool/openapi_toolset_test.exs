defmodule ADK.Tool.OpenApiTool.OpenApiToolsetTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.OpenApiTool.OpenApiToolset
  alias ADK.Tool.OpenApiTool.RestApiTool

  defp load_spec(file_path) do
    {:ok, yaml} = YamlElixir.read_from_file(file_path)
    yaml
  end

  defp get_openapi_spec do
    current_dir = Path.dirname(__ENV__.file)
    yaml_path = Path.join(current_dir, "test.yaml")
    load_spec(yaml_path)
  end

  test "openapi_toolset_initialization_from_dict" do
    spec = get_openapi_spec()
    toolset = OpenApiToolset.new(spec_dict: spec)

    assert is_list(toolset.tools)
    assert length(toolset.tools) == 5
    assert Enum.all?(toolset.tools, fn tool -> %RestApiTool{} = tool end)
  end

  test "openapi_toolset_initialization_from_yaml_string" do
    current_dir = Path.dirname(__ENV__.file)
    yaml_path = Path.join(current_dir, "test.yaml")
    spec_str = File.read!(yaml_path)

    toolset = OpenApiToolset.new(spec_str: spec_str, spec_str_type: "yaml")

    assert is_list(toolset.tools)
    assert length(toolset.tools) == 5
    assert Enum.all?(toolset.tools, fn tool -> %RestApiTool{} = tool end)
  end

  test "openapi_toolset_tool_existing" do
    spec = get_openapi_spec()
    toolset = OpenApiToolset.new(spec_dict: spec)

    tool_name = "calendar_calendars_insert"
    tool = OpenApiToolset.get_tool(toolset, tool_name)

    assert %RestApiTool{} = tool
    assert tool.name == tool_name
    assert tool.description == "Creates a secondary calendar."
    assert tool.endpoint.method == "post"
    assert tool.endpoint.base_url == "https://www.googleapis.com/calendar/v3"
    assert tool.endpoint.path == "/calendars"
    assert tool.is_long_running == false
    assert tool.operation["operationId"] == "calendar.calendars.insert"
    assert tool.operation["description"] == "Creates a secondary calendar."
    assert not is_nil(get_in(tool.operation, ["requestBody", "content", "application/json"]))
    assert map_size(tool.operation["responses"]) == 1

    response = tool.operation["responses"]["200"]
    assert response["description"] == "Successful response"
    assert not is_nil(get_in(response, ["content", "application/json"]))

    # auth scheme could be a map because of Elixir parsing
    assert is_map(tool.auth_scheme)

    tool_name2 = "calendar_calendars_get"
    tool2 = OpenApiToolset.get_tool(toolset, tool_name2)

    assert %RestApiTool{} = tool2
    assert tool2.name == tool_name2
    assert tool2.description == "Returns metadata for a calendar."
    assert tool2.endpoint.method == "get"
    assert tool2.endpoint.base_url == "https://www.googleapis.com/calendar/v3"
    assert tool2.endpoint.path == "/calendars/{calendarId}"
    assert tool2.is_long_running == false
    assert tool2.operation["operationId"] == "calendar.calendars.get"
    assert tool2.operation["description"] == "Returns metadata for a calendar."
    assert length(tool2.operation["parameters"]) == 8

    first_param = Enum.at(tool2.operation["parameters"], 0)
    assert first_param["name"] == "calendarId"
    assert first_param["in"] == "path"
    assert first_param["required"] == true
    assert first_param["schema"]["type"] == "string"

    assert first_param["description"] ==
             "Calendar identifier. To retrieve calendar IDs call the calendarList.list method. If you want to access the primary calendar of the currently logged in user, use the \"primary\" keyword."

    assert is_map(tool2.auth_scheme)

    assert %RestApiTool{} = OpenApiToolset.get_tool(toolset, "calendar_calendars_update")
    assert %RestApiTool{} = OpenApiToolset.get_tool(toolset, "calendar_calendars_delete")
    assert %RestApiTool{} = OpenApiToolset.get_tool(toolset, "calendar_calendars_patch")
  end

  test "openapi_toolset_tool_non_existing" do
    spec = get_openapi_spec()
    toolset = OpenApiToolset.new(spec_dict: spec)

    tool = OpenApiToolset.get_tool(toolset, "non_existent_tool")
    assert is_nil(tool)
  end

  test "openapi_toolset_configure_auth_on_init" do
    spec = get_openapi_spec()
    auth_scheme = %{"in" => "header", "name" => "api_key", "type" => "apiKey"}
    auth_credential = %{"auth_type" => "API_KEY"}

    toolset =
      OpenApiToolset.new(
        spec_dict: spec,
        auth_scheme: auth_scheme,
        auth_credential: auth_credential
      )

    assert Enum.all?(toolset.tools, fn tool -> tool.auth_scheme == auth_scheme end)
    assert Enum.all?(toolset.tools, fn tool -> tool.auth_credential == auth_credential end)
  end

  test "openapi_toolset_verify_on_init_with_path" do
    spec = get_openapi_spec()
    verify_value = "/path/to/enterprise-ca-bundle.crt"
    toolset = OpenApiToolset.new(spec_dict: spec, ssl_verify: verify_value)

    assert Enum.all?(toolset.tools, fn tool -> tool.ssl_verify == verify_value end)
  end

  test "openapi_toolset_verify_on_init_with_false" do
    spec = get_openapi_spec()
    verify_value = false
    toolset = OpenApiToolset.new(spec_dict: spec, ssl_verify: verify_value)

    assert Enum.all?(toolset.tools, fn tool -> tool.ssl_verify == verify_value end)
  end

  test "openapi_toolset_configure_verify_all" do
    spec = get_openapi_spec()
    toolset = OpenApiToolset.new(spec_dict: spec)

    # Initially verify should be nil
    assert Enum.all?(toolset.tools, fn tool -> tool.ssl_verify == nil end)

    ca_bundle_path = "/path/to/custom-ca.crt"
    toolset = OpenApiToolset.configure_ssl_verify_all(toolset, ca_bundle_path)

    assert Enum.all?(toolset.tools, fn tool -> tool.ssl_verify == ca_bundle_path end)
  end

  test "openapi_toolset_tool_name_prefix" do
    spec = get_openapi_spec()
    prefix = "my_api"
    toolset = OpenApiToolset.new(spec_dict: spec, tool_name_prefix: prefix)

    assert toolset.tool_name_prefix == prefix

    prefixed_tools = OpenApiToolset.get_tools_with_prefix(toolset)
    assert length(prefixed_tools) == 5

    assert Enum.all?(prefixed_tools, fn tool -> String.starts_with?(tool.name, "#{prefix}_") end)

    expected_prefixed_name = "my_api_calendar_calendars_insert"
    prefixed_tool_names = Enum.map(prefixed_tools, & &1.name)
    assert expected_prefixed_name in prefixed_tool_names
  end

  test "openapi_toolset_header_provider" do
    spec = get_openapi_spec()

    my_header_provider = fn _context ->
      %{"X-Custom-Header" => "custom-value", "X-Request-ID" => "12345"}
    end

    toolset =
      OpenApiToolset.new(
        spec_dict: spec,
        header_provider: my_header_provider
      )

    assert toolset.header_provider == my_header_provider
    assert Enum.all?(toolset.tools, fn tool -> tool.header_provider == my_header_provider end)
  end

  test "openapi_toolset_header_provider_none_by_default" do
    spec = get_openapi_spec()
    toolset = OpenApiToolset.new(spec_dict: spec)

    assert toolset.header_provider == nil
    assert Enum.all?(toolset.tools, fn tool -> tool.header_provider == nil end)
  end

  test "openapi_toolset_preserve_property_names" do
    spec = get_openapi_spec()
    toolset = OpenApiToolset.new(spec_dict: spec, preserve_property_names: true)

    tool = OpenApiToolset.get_tool(toolset, "calendar_calendars_get")
    assert not is_nil(tool)

    param_names = Enum.map(tool.parameters, & &1.py_name)
    assert "calendarId" in param_names
  end

  test "openapi_toolset_default_snake_case_conversion" do
    spec = get_openapi_spec()
    toolset = OpenApiToolset.new(spec_dict: spec)

    tool = OpenApiToolset.get_tool(toolset, "calendar_calendars_get")
    assert not is_nil(tool)

    param_names = Enum.map(tool.parameters, & &1.py_name)
    assert "calendar_id" in param_names
    assert "calendarId" not in param_names
  end

  test "openapi_toolset_preserve_property_names_body_params" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Test API", "version" => "1.0"},
      "servers" => [%{"url" => "https://api.example.com"}],
      "paths" => %{
        "/users" => %{
          "post" => %{
            "operationId" => "createUser",
            "requestBody" => %{
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "firstName" => %{"type" => "string"},
                      "lastName" => %{"type" => "string"},
                      "emailAddress" => %{"type" => "string"}
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

    # With preserve_property_names: true
    toolset = OpenApiToolset.new(spec_dict: spec, preserve_property_names: true)
    tool = OpenApiToolset.get_tool(toolset, "create_user")

    param_names = Enum.map(tool.parameters, & &1.py_name)
    assert "firstName" in param_names
    assert "lastName" in param_names
    assert "emailAddress" in param_names

    # Without preserve_property_names (default)
    toolset_default = OpenApiToolset.new(spec_dict: spec)
    tool_default = OpenApiToolset.get_tool(toolset_default, "create_user")

    param_names_default = Enum.map(tool_default.parameters, & &1.py_name)
    assert "first_name" in param_names_default
    assert "last_name" in param_names_default
    assert "email_address" in param_names_default
  end
end
