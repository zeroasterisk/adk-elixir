defmodule ADK.Tool.OpenApiTool.SpecParser do
  @moduledoc """
  Parses an OpenAPI specification into a list of operations.
  """
  
  alias ADK.Utils.Common

  defmodule OperationEndpoint do
    defstruct [:base_url, :path, :method]
  end

  defmodule ApiParameter do
    defstruct [:original_name, :param_location, :param_schema, description: "", py_name: "", type_value: nil, type_hint: nil, required: false]
  end

  defmodule ParsedOperation do
    defstruct [:name, :description, :endpoint, :operation, parameters: [], return_value: nil, auth_scheme: nil, auth_credential: nil, additional_context: %{}]
  end

  @valid_schema_types ~w(array boolean integer null number object string)
  @schema_container_keys ~w(schema schemas)

  @doc """
  Parses an OpenAPI spec dictionary into a list of ParsedOperation structs.
  """
  def parse(openapi_spec_dict, opts \\ [])

  def parse(openapi_spec_dict, opts) when is_map(openapi_spec_dict) do
    preserve_property_names = Keyword.get(opts, :preserve_property_names, false)

    openapi_spec_dict
    |> resolve_references()
    |> sanitize_schema_types()
    |> collect_operations(preserve_property_names)
  end

  def parse(_, _), do: raise(ArgumentError, "Expected a map for openapi_spec")

  # --- Reference Resolution ---

  defp resolve_references(spec) do
    recursive_resolve(spec, spec, MapSet.new(), %{}) |> elem(0)
  end

  defp recursive_resolve(%{"$ref" => ref_string} = obj, current_doc, seen_refs, resolved_cache) when is_binary(ref_string) do
    if not String.starts_with?(ref_string, "#") do
      raise ArgumentError, "External references not supported: #{ref_string}"
    end

    if MapSet.member?(seen_refs, ref_string) and not Map.has_key?(resolved_cache, ref_string) do
      # Circular ref detected
      {Map.delete(obj, "$ref"), resolved_cache}
    else
      seen_refs = MapSet.put(seen_refs, ref_string)
      
      if Map.has_key?(resolved_cache, ref_string) do
        {Map.get(resolved_cache, ref_string), resolved_cache}
      else
        resolved_value = resolve_ref_path(ref_string, current_doc)
        if is_nil(resolved_value) do
          {obj, resolved_cache}
        else
          {resolved_value, new_cache} = recursive_resolve(resolved_value, current_doc, seen_refs, resolved_cache)
          new_cache = Map.put(new_cache, ref_string, resolved_value)
          {resolved_value, new_cache}
        end
      end
    end
  end

  defp recursive_resolve(obj, current_doc, seen_refs, resolved_cache) when is_map(obj) do
    Enum.reduce(obj, {%{}, resolved_cache}, fn {k, v}, {acc_map, acc_cache} ->
      {new_v, new_cache} = recursive_resolve(v, current_doc, seen_refs, acc_cache)
      {Map.put(acc_map, k, new_v), new_cache}
    end)
  end

  defp recursive_resolve(obj, current_doc, seen_refs, resolved_cache) when is_list(obj) do
    Enum.reduce(obj, {[], resolved_cache}, fn item, {acc_list, acc_cache} ->
      {new_item, new_cache} = recursive_resolve(item, current_doc, seen_refs, acc_cache)
      {acc_list ++ [new_item], new_cache}
    end)
  end

  defp recursive_resolve(obj, _current_doc, _seen_refs, resolved_cache), do: {obj, resolved_cache}

  defp resolve_ref_path(ref_string, current_doc) do
    parts = String.split(ref_string, "/") |> tl() # remove the "#"
    Enum.reduce_while(parts, current_doc, fn part, acc ->
      if is_map(acc) and Map.has_key?(acc, part) do
        {:cont, Map.get(acc, part)}
      else
        {:halt, nil}
      end
    end)
  end

  # --- Schema Sanitization ---

  def sanitize_schema_types(spec) do
    sanitize_recursive(spec, false)
  end

  defp sanitize_recursive(obj, in_schema) when is_map(obj) do
    obj = if in_schema, do: sanitize_type_field(obj), else: obj

    Map.new(obj, fn {k, v} ->
      is_schema_key = in_schema or (k in @schema_container_keys)
      {k, sanitize_recursive(v, is_schema_key)}
    end)
  end

  defp sanitize_recursive(obj, in_schema) when is_list(obj) do
    Enum.map(obj, &sanitize_recursive(&1, in_schema))
  end

  defp sanitize_recursive(obj, _), do: obj

  defp sanitize_type_field(%{"type" => type_val} = dict) when is_binary(type_val) do
    normalized = String.downcase(type_val)
    if normalized in @valid_schema_types do
      Map.put(dict, "type", normalized)
    else
      Map.delete(dict, "type")
    end
  end

  defp sanitize_type_field(%{"type" => type_val} = dict) when is_list(type_val) do
    valid_types = 
      type_val
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&(&1 in @valid_schema_types))
      |> Enum.uniq()

    if valid_types == [] do
      Map.delete(dict, "type")
    else
      Map.put(dict, "type", valid_types)
    end
  end

  defp sanitize_type_field(dict), do: dict

  # --- Operation Collection ---

  defp collect_operations(spec, preserve_property_names) do
    base_url = get_base_url(spec)
    
    global_scheme_name = case get_in(spec, ["security"]) do
      [first | _] when is_map(first) -> List.first(Map.keys(first))
      _ -> nil
    end

    auth_schemes = get_in(spec, ["components", "securitySchemes"]) || %{}

    paths = Map.get(spec, "paths", %{}) || %{}

    Enum.flat_map(paths, fn {path, path_item} ->
      if is_map(path_item) do
        path_params = Map.get(path_item, "parameters", [])
        
        ~w(get post put delete patch head options trace)
        |> Enum.map(fn method -> {method, Map.get(path_item, method)} end)
        |> Enum.filter(fn {_, op} -> is_map(op) end)
        |> Enum.map(fn {method, op_dict} ->
          op_dict = Map.update(op_dict, "parameters", path_params, &(&1 ++ path_params))
          op_dict = if Map.has_key?(op_dict, "operationId") do
            op_dict
          else
            Map.put(op_dict, "operationId", Common.to_snake_case("#{path}_#{method}"))
          end
          
          url = %OperationEndpoint{base_url: base_url, path: path, method: method}
          
          auth_scheme_name = get_op_auth_scheme_name(op_dict) || global_scheme_name
          auth_scheme = if auth_scheme_name, do: Map.get(auth_schemes, auth_scheme_name), else: nil
          
          {params, return_val} = parse_operation_params(op_dict, preserve_property_names)
          
          description = Map.get(op_dict, "description") || Map.get(op_dict, "summary") || ""
          name = get_function_name(Map.get(op_dict, "operationId"))

          %ParsedOperation{
            name: name,
            description: description,
            endpoint: url,
            operation: op_dict,
            parameters: params,
            return_value: return_val,
            auth_scheme: auth_scheme,
            auth_credential: nil,
            additional_context: %{}
          }
        end)
      else
        []
      end
    end)
  end

  defp get_base_url(spec) do
    case Map.get(spec, "servers") do
      [first | _] when is_map(first) -> Map.get(first, "url", "")
      _ -> ""
    end
  end

  defp get_op_auth_scheme_name(op_dict) do
    case Map.get(op_dict, "security") do
      [first | _] when is_map(first) -> List.first(Map.keys(first))
      _ -> nil
    end
  end

  defp get_function_name(operation_id) when is_binary(operation_id) do
    operation_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> Common.to_snake_case()
    |> String.slice(0, 60)
  end
  defp get_function_name(_), do: raise(ArgumentError, "Operation ID is missing")

  defp parse_operation_params(op_dict, preserve_property_names) do
    # 1. Process operation parameters
    raw_params = Map.get(op_dict, "parameters", [])
    
    params = Enum.map(raw_params, fn p ->
      original_name = Map.get(p, "name", "")
      description = Map.get(p, "description", "")
      location = Map.get(p, "in", "")
      schema = Map.get(p, "schema", %{})
      required = Map.get(p, "required", false)

      %ApiParameter{
        original_name: original_name,
        param_location: location,
        param_schema: schema,
        description: description,
        required: required,
        py_name: get_py_name(original_name, preserve_property_names)
      }
    end)

    # 2. Process request body
    body_params = process_request_body(Map.get(op_dict, "requestBody"), preserve_property_names)
    params = params ++ body_params

    # 3. Deduplicate param names
    params = dedupe_param_names(params)

    # 4. Process return value
    return_val = process_return_value(Map.get(op_dict, "responses", %{}))

    {params, return_val}
  end

  defp process_request_body(nil, _), do: []
  defp process_request_body(request_body, preserve_property_names) when is_map(request_body) do
    content = Map.get(request_body, "content", %{})
    
    # Process first mime type only
    case Enum.at(content, 0) do
      {_, media_type_object} when is_map(media_type_object) ->
        schema = Map.get(media_type_object, "schema", %{})
        description = Map.get(request_body, "description", "")
        
        type = Map.get(schema, "type")
        
        cond do
          type == "object" ->
            properties = Map.get(schema, "properties", %{})
            Enum.map(properties, fn {prop_name, prop_details} ->
              prop_desc = Map.get(prop_details, "description", "")
              %ApiParameter{
                original_name: prop_name,
                param_location: "body",
                param_schema: prop_details,
                description: prop_desc,
                py_name: get_py_name(prop_name, preserve_property_names)
              }
            end)
          
          type == "array" ->
            [
              %ApiParameter{
                original_name: "array",
                param_location: "body",
                param_schema: schema,
                description: description,
                py_name: "array"
              }
            ]
            
          true ->
            # Default to "body" for oneOf/anyOf/allOf or empty type
            param_name = if (Map.has_key?(schema, "oneOf") or Map.has_key?(schema, "anyOf") or Map.has_key?(schema, "allOf")) or (not Map.has_key?(schema, "type")), do: "body", else: ""
            [
              %ApiParameter{
                original_name: param_name,
                param_location: "body",
                param_schema: schema,
                description: description,
                py_name: param_name
              }
            ]
        end
      _ ->
        []
    end
  end
  defp process_request_body(_, _), do: []

  defp dedupe_param_names(params) do
    {deduped, _} = Enum.reduce(params, {[], %{}}, fn param, {acc, counts} ->
      name = if param.py_name == "", do: param.original_name |> Common.to_snake_case(), else: param.py_name
      name = if name == "", do: default_py_name(param.param_location), else: name
      
      {final_name, new_counts} = case Map.get(counts, name) do
        nil -> {name, Map.put(counts, name, 1)}
        count -> {"#{name}_#{count}", Map.put(counts, name, count + 1)}
      end
      
      updated_param = %{param | py_name: final_name}
      {acc ++ [updated_param], new_counts}
    end)
    deduped
  end

  defp get_py_name(original_name, true), do: original_name
  defp get_py_name(original_name, false), do: Common.to_snake_case(original_name)

  defp default_py_name("body"), do: "body"
  defp default_py_name("query"), do: "query_param"
  defp default_py_name("path"), do: "path_param"
  defp default_py_name("header"), do: "header_param"
  defp default_py_name("cookie"), do: "cookie_param"
  defp default_py_name(_), do: "value"

  defp process_return_value(responses) when is_map(responses) do
    # Find smallest 20x response
    valid_keys = Map.keys(responses) |> Enum.filter(&String.starts_with?(&1, "2"))
    
    min_20x = if valid_keys != [], do: Enum.min(valid_keys), else: nil
    
    return_schema = if min_20x do
      content = get_in(responses, [min_20x, "content"]) || %{}
      case Enum.at(content, 0) do
        {_, mime_details} when is_map(mime_details) -> Map.get(mime_details, "schema", %{})
        _ -> %{}
      end
    else
      %{}
    end

    %ApiParameter{
      original_name: "",
      param_location: "",
      param_schema: return_schema
    }
  end
  defp process_return_value(_), do: %ApiParameter{original_name: "", param_location: "", param_schema: %{}}
end
