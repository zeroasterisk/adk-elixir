defmodule ADK.Tool.OpenApiTool.RestApiTool do
  @moduledoc """
  A tool that represents a single operation from an OpenAPI specification.
  """

  alias ADK.Tool.OpenApiTool.SpecParser.ParsedOperation

  defstruct [
    :name,
    :description,
    :endpoint,
    :operation,
    :parameters,
    :auth_scheme,
    :auth_credential,
    :ssl_verify,
    :header_provider,
    :is_long_running
  ]

  @doc """
  Create a new RestApiTool from a ParsedOperation.
  """
  def from_parsed_operation(%ParsedOperation{} = parsed, opts \\ []) do
    %__MODULE__{
      name: parsed.name,
      description: parsed.description,
      endpoint: parsed.endpoint,
      operation: parsed.operation,
      parameters: parsed.parameters,
      auth_scheme: Keyword.get(opts, :auth_scheme) || parsed.auth_scheme,
      auth_credential: Keyword.get(opts, :auth_credential) || parsed.auth_credential,
      ssl_verify: Keyword.get(opts, :ssl_verify),
      header_provider: Keyword.get(opts, :header_provider),
      is_long_running: false
    }
  end

  @doc """
  Converts a snake_case string to a lowerCamelCase string.
  """
  def snake_to_lower_camel(""), do: ""

  def snake_to_lower_camel(snake_case_string) do
    if not String.contains?(snake_case_string, "_") do
      snake_case_string
    else
      [head | tail] = String.split(snake_case_string, "_")
      head <> Enum.map_join(tail, "", &String.capitalize/1)
    end
  end

  @doc """
  Executes the REST API call.
  """
  def call(%__MODULE__{} = tool, args, tool_context \\ nil) do
    if tool.auth_scheme && is_nil(tool.auth_credential) do
      # Return auth pending if auth required but no creds provided
      %{"pending" => true, "message" => "Needs your authorization to access your data."}
    else
      do_call(tool, args, tool_context)
    end
  end

  defp do_call(tool, args, _tool_context) do
    {auth_param, auth_args} =
      if tool.auth_scheme && tool.auth_credential do
        ADK.Tool.OpenApiTool.Auth.AuthHelpers.credential_to_param(
          tool.auth_scheme,
          tool.auth_credential
        )
      else
        {nil, %{}}
      end

    all_params = tool.parameters || []

    all_params =
      if auth_param do
        # In elixir we simulate ApiParameter
        p = %ADK.Tool.OpenApiTool.SpecParser.ApiParameter{
          original_name: auth_param.original_name,
          py_name: auth_param.py_name,
          param_location: auth_param.param_location,
          param_schema: auth_param.param_schema
        }

        [p | all_params]
      else
        all_params
      end

    args_with_auth = Enum.into(args, %{}, fn {k, v} -> {to_string(k), v} end)

    args_with_auth =
      Map.merge(
        args_with_auth,
        Enum.into(auth_args || %{}, %{}, fn {k, v} -> {to_string(k), v} end)
      )

    req_params = prepare_request_params(tool, all_params, args_with_auth)

    headers = Enum.map(req_params.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    req_opts = [
      method: req_params.method,
      url: req_params.url,
      params: req_params.params,
      headers: headers,
      retry: false
    ]

    req_opts =
      if Map.has_key?(req_params, :json),
        do: Keyword.put(req_opts, :json, req_params.json),
        else: req_opts

    req_opts =
      if Map.has_key?(req_params, :form),
        do: Keyword.put(req_opts, :form, req_params.form),
        else: req_opts

    req_opts =
      if Map.has_key?(req_params, :body),
        do: Keyword.put(req_opts, :body, req_params.body),
        else: req_opts

    req_opts =
      case tool.ssl_verify do
        false -> Keyword.put(req_opts, :connect_options, transport_opts: [verify: :verify_none])
        true -> Keyword.put(req_opts, :connect_options, transport_opts: [verify: :verify_peer])
        _ -> req_opts
      end

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: status, body: body}} ->
        error_details = if is_binary(body), do: body, else: Jason.encode!(body)

        error_msg =
          "Tool #{tool.name} execution failed. Analyze this execution error and your inputs. Retry with adjustments if applicable. But make sure don't retry more than 3 times. Execution Error: Status Code: #{status}, #{error_details}"

        %{"error" => error_msg}

      {:error, reason} ->
        %{"error" => "Request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Prepares the request parameters for the API call.
  """
  def prepare_request_params(%__MODULE__{} = tool, parameters, kwargs) do
    method =
      (tool.endpoint.method || "GET")
      |> to_string()
      |> String.downcase()
      |> String.to_atom()

    params_map = Map.new(parameters || [], fn p -> {p.py_name, p} end)

    acc = %{
      path_params: %{},
      query_params: %{},
      header_params: %{"User-Agent" => "google-adk/elixir (tool: #{tool.name})"},
      cookie_params: %{}
    }

    acc =
      Enum.reduce(kwargs || %{}, acc, fn {param_k, v}, acc ->
        case Map.get(params_map, to_string(param_k)) do
          nil ->
            acc

          param_obj ->
            original_k = param_obj.original_name

            case param_obj.param_location do
              "path" -> put_in(acc.path_params[original_k], v)
              "query" -> if v, do: put_in(acc.query_params[original_k], v), else: acc
              "header" -> put_in(acc.header_params[original_k], v)
              "cookie" -> put_in(acc.cookie_params[original_k], v)
              _ -> acc
            end
        end
      end)

    base_url = tool.endpoint.base_url || ""

    base_url =
      if String.ends_with?(base_url, "/"), do: String.slice(base_url, 0..-2//1), else: base_url

    path =
      Enum.reduce(acc.path_params, tool.endpoint.path || "", fn {k, v}, p ->
        String.replace(p, "{#{k}}", to_string(v))
      end)

    url = base_url <> path

    {clean_url, query_params} = extract_embedded_query(url, acc.query_params)
    clean_url = hd(String.split(clean_url, "#"))

    body_kwargs = build_body(tool.operation || %{}, parameters || [], kwargs || %{})

    {content_type, body_kwargs} = Map.pop(body_kwargs, :content_type)

    acc =
      if content_type do
        put_in(acc.header_params["Content-Type"], content_type)
      else
        acc
      end

    filtered_query_params = :maps.filter(fn _k, v -> not is_nil(v) end, query_params)

    request_params = %{
      method: method,
      url: clean_url,
      params: filtered_query_params,
      headers: acc.header_params || %{},
      cookies: acc.cookie_params
    }

    Map.merge(request_params, body_kwargs)
  end

  defp extract_embedded_query(url, explicit_query_params) do
    case URI.parse(url) do
      %URI{query: nil} ->
        {url, explicit_query_params}

      %URI{query: q} = uri ->
        embedded_query = URI.decode_query(q)
        merged_query = Map.merge(embedded_query, explicit_query_params)
        clean_url = to_string(%{uri | query: nil})
        {clean_url, merged_query}

      _ ->
        {url, explicit_query_params}
    end
  end

  defp build_body(%{"requestBody" => %{"content" => content}}, parameters, kwargs)
       when is_map(content) and map_size(content) > 0 do
    {mime_type, media_type_object} = Enum.at(content, 0)
    schema = media_type_object["schema"] || %{}

    body_data =
      case schema["type"] do
        "object" ->
          Enum.reduce(parameters, %{}, fn param, acc ->
            if param.param_location == "body" and Map.has_key?(kwargs, param.py_name) do
              Map.put(acc, param.original_name, Map.get(kwargs, param.py_name))
            else
              acc
            end
          end)

        "array" ->
          Enum.find_value(parameters, nil, fn param ->
            if param.param_location == "body" and param.py_name == "array" do
              Map.get(kwargs, "array")
            end
          end)

        _ ->
          Enum.find_value(parameters, nil, fn param ->
            if param.param_location == "body" and
                 (param.original_name == "" or is_nil(param.original_name)) do
              Map.get(kwargs, param.py_name)
            end
          end)
      end

    body_kwargs =
      case mime_type do
        m when m in ["application/json"] or binary_part(m, byte_size(m) - 5, 5) == "+json" ->
          if body_data, do: %{json: body_data}, else: %{}

        "application/x-www-form-urlencoded" ->
          %{form: body_data}

        "multipart/form-data" ->
          %{form: body_data}

        "application/octet-stream" ->
          %{body: body_data}

        "text/plain" ->
          %{body: body_data}

        _ ->
          %{}
      end

    if mime_type do
      Map.put(body_kwargs, :content_type, mime_type)
    else
      body_kwargs
    end
  end

  defp build_body(_, _, _), do: %{}
end
