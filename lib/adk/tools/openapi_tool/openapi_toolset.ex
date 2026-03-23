defmodule ADK.Tool.OpenApiTool.OpenApiToolset do
  @moduledoc """
  Tool set that generates tools from an OpenAPI specification.
  """

  alias ADK.Tool.OpenApiTool.SpecParser
  alias ADK.Tool.OpenApiTool.RestApiTool

  defstruct [
    :tools,
    :auth_scheme,
    :auth_credential,
    :ssl_verify,
    :tool_name_prefix,
    :header_provider
  ]

  @doc """
  Initializes an OpenAPIToolset with the given options.
  Options:
    * `:spec_dict` - The OpenAPI spec as a map.
    * `:spec_str` - The OpenAPI spec as a string.
    * `:spec_str_type` - Expected format of `spec_str` ("yaml" or "json").
    * `:auth_scheme` - The auth scheme to use.
    * `:auth_credential` - The auth credential to use.
    * `:ssl_verify` - SSL verification configuration.
    * `:tool_name_prefix` - Prefix for the generated tool names.
    * `:header_provider` - Function providing additional headers.
    * `:preserve_property_names` - Whether to preserve original property names (camelCase) instead of snake_case.
  """
  def new(opts \\ []) do
    spec_dict = Keyword.get(opts, :spec_dict)
    spec_str = Keyword.get(opts, :spec_str)
    spec_str_type = Keyword.get(opts, :spec_str_type, "yaml")

    spec =
      cond do
        is_map(spec_dict) ->
          spec_dict

        is_binary(spec_str) and spec_str_type == "yaml" ->
          case YamlElixir.read_from_string(spec_str) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        true ->
          %{}
      end

    preserve = Keyword.get(opts, :preserve_property_names, false)
    parsed_operations = SpecParser.parse(spec, preserve_property_names: preserve)

    auth_scheme = Keyword.get(opts, :auth_scheme)
    auth_credential = Keyword.get(opts, :auth_credential)
    ssl_verify = Keyword.get(opts, :ssl_verify)
    tool_name_prefix = Keyword.get(opts, :tool_name_prefix)
    header_provider = Keyword.get(opts, :header_provider)

    tools =
      Enum.map(parsed_operations, fn parsed ->
        # Override auth details if provided in toolset config
        parsed = if auth_scheme, do: %{parsed | auth_scheme: auth_scheme}, else: parsed

        parsed =
          if auth_credential, do: %{parsed | auth_credential: auth_credential}, else: parsed

        # Apply prefix
        name =
          if is_binary(tool_name_prefix) and tool_name_prefix != "" do
            "#{tool_name_prefix}_#{parsed.name}"
          else
            parsed.name
          end

        parsed = %{parsed | name: name}

        RestApiTool.from_parsed_operation(parsed,
          ssl_verify: ssl_verify,
          header_provider: header_provider
        )
      end)

    %__MODULE__{
      tools: tools,
      auth_scheme: auth_scheme,
      auth_credential: auth_credential,
      ssl_verify: ssl_verify,
      tool_name_prefix: tool_name_prefix,
      header_provider: header_provider
    }
  end

  @doc """
  Gets a tool by name.
  """
  def get_tool(%__MODULE__{tools: tools}, tool_name) do
    Enum.find(tools, fn t -> t.name == tool_name end)
  end

  @doc """
  Gets all tools with the configured prefix.
  """
  def get_tools_with_prefix(%__MODULE__{tools: tools, tool_name_prefix: prefix})
      when is_binary(prefix) and prefix != "" do
    Enum.filter(tools, fn t -> String.starts_with?(t.name, "#{prefix}_") end)
  end

  def get_tools_with_prefix(%__MODULE__{tools: tools}), do: tools

  @doc """
  Configures ssl_verify on all tools in the toolset.
  """
  def configure_ssl_verify_all(%__MODULE__{} = toolset, ssl_verify) do
    tools = Enum.map(toolset.tools, fn t -> %{t | ssl_verify: ssl_verify} end)
    %{toolset | tools: tools, ssl_verify: ssl_verify}
  end
end
