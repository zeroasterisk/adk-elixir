defmodule ADK.ApigeeLlm do
  @moduledoc """
  Apigee LLM router.

  Parses model strings starting with `apigee/` and dispatches to the correct backend
  with `base_url` pointing to the Apigee proxy.
  """
  @behaviour ADK.LLM

  @impl true
  def generate(model, request) do
    proxy_url = Map.get(request, :apigee_proxy_url) || ADK.Config.apigee_proxy_url()
    custom_headers = Map.get(request, :custom_headers, [])
    api_type = Map.get(request, :apigee_api_type, :unknown)

    case parse_model(model, api_type) do
      {:ok,
       %{backend: backend, model_id: model_id, api_version: api_version, is_vertexai: is_vertexai}} ->
        if is_vertexai do
          project = ADK.Config.google_cloud_project()
          location = ADK.Config.google_cloud_location()

          if is_nil(project) or is_nil(location) do
            raise ArgumentError,
                  "GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION environment variable must be set"
          end
        end

        base_url = build_base_url(proxy_url, %{is_vertexai: is_vertexai, api_version: api_version, backend: backend})

        # Inject apigee settings into request
        request = Map.put(request, :base_url, base_url)
        request = Map.put(request, :custom_headers, custom_headers)

        backend.generate(model_id, request)

      {:error, reason} ->
        raise ArgumentError, "Invalid model string: #{model} (#{reason})"
    end
  end

  defp validate_model_string(model) do
    case String.split(model, "/") do
      ["apigee", ""] -> false
      ["apigee", _model] -> true
      ["apigee", type, version, _model] when type in ["vertex_ai", "gemini", "openai"] ->
        String.starts_with?(version, "v")
      ["apigee", type, _model] when type in ["vertex_ai", "gemini", "openai"] -> true
      ["apigee", version, _model] -> String.starts_with?(version, "v")
      _ -> false
    end
  end

  defp parse_model(model, api_type) do
    if not validate_model_string(model) do
      {:error, :invalid_format}
    else
      parts = String.split(model, "/")

      {model_id, api_version, default_backend, is_vertexai} = parse_parts(parts)

      backend =
        case api_type do
          :chat_completions -> ADK.LLM.OpenAI
          :genai -> ADK.LLM.Gemini
          _ -> default_backend
        end

      {:ok,
       %{backend: backend, model_id: model_id, api_version: api_version, is_vertexai: is_vertexai}}
    end
  end

  defp parse_parts(["apigee", "openai", "v1" | rest]) do
    {Enum.join(rest, "/"), "v1", ADK.LLM.OpenAI, false}
  end
  defp parse_parts(["apigee", "openai" | rest]) do
    {Enum.join(rest, "/"), nil, ADK.LLM.OpenAI, false}
  end
  defp parse_parts(["apigee", "vertex_ai", "v1beta" | rest]) do
    {Enum.join(rest, "/"), "v1beta", ADK.LLM.Gemini, true}
  end
  defp parse_parts(["apigee", "vertex_ai" | rest]) do
    {Enum.join(rest, "/"), nil, ADK.LLM.Gemini, true}
  end
  defp parse_parts(["apigee", "gemini", "v1" | rest]) do
    {Enum.join(rest, "/"), "v1", ADK.LLM.Gemini, false}
  end
  defp parse_parts(["apigee", "gemini" | rest]) do
    {Enum.join(rest, "/"), nil, ADK.LLM.Gemini, false}
  end
  defp parse_parts(["apigee", version | rest]) when version in ["v1", "v1beta"] do
    {Enum.join(rest, "/"), version, ADK.LLM.Gemini, use_vertex_env?()}
  end
  defp parse_parts(["apigee" | rest]) do
    {Enum.join(rest, "/"), nil, ADK.LLM.Gemini, use_vertex_env?()}
  end

  defp use_vertex_env? do
    ADK.Config.google_genai_use_vertexai()
  end

  defp build_base_url(proxy_url, %{is_vertexai: is_vertexai, api_version: api_version, backend: backend}) do
    proxy_url = String.trim_trailing(proxy_url || "", "/")

    if backend == ADK.LLM.OpenAI do
      version = api_version || "v1"
      "#{proxy_url}/#{version}"
    else
      if is_vertexai do
        version = api_version || "v1beta"
        project = ADK.Config.google_cloud_project()
        location = ADK.Config.google_cloud_location()

        "#{proxy_url}/#{version}/projects/#{project}/locations/#{location}/publishers/google/models"
      else
        version = api_version || "v1beta"
        "#{proxy_url}/#{version}/models"
      end
    end
  end
end
