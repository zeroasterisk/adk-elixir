defmodule ADK.ApigeeLlm do
  @moduledoc """
  Apigee LLM router.

  Parses model strings starting with `apigee/` and dispatches to the correct backend
  with `base_url` pointing to the Apigee proxy.
  """
  @behaviour ADK.LLM

  @impl true
  def generate(model, request) do
    proxy_url = Map.get(request, :apigee_proxy_url) || System.get_env("APIGEE_PROXY_URL")
    custom_headers = Map.get(request, :custom_headers, [])
    api_type = Map.get(request, :apigee_api_type, :unknown)

    case parse_model(model, api_type) do
      {:ok,
       %{backend: backend, model_id: model_id, api_version: api_version, is_vertexai: is_vertexai}} ->
        if is_vertexai do
          project = System.get_env("GOOGLE_CLOUD_PROJECT")
          location = System.get_env("GOOGLE_CLOUD_LOCATION")

          if is_nil(project) or is_nil(location) do
            raise ArgumentError,
                  "GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION environment variable must be set"
          end
        end

        base_url = build_base_url(proxy_url, is_vertexai, api_version, backend)

        # Inject apigee settings into request
        request = Map.put(request, :base_url, base_url)
        request = Map.put(request, :custom_headers, custom_headers)

        backend.generate(model_id, request)

      {:error, reason} ->
        raise ArgumentError, "Invalid model string: #{model} (#{reason})"
    end
  end

  defp validate_model_string(model) do
    if not String.starts_with?(model, "apigee/") do
      false
    else
      stripped = String.trim_leading(model, "apigee/")

      if stripped == "" do
        false
      else
        components = String.split(stripped, "/")

        cond do
          length(components) == 1 ->
            true

          length(components) > 3 ->
            false

          length(components) == 3 ->
            Enum.at(components, 0) in ["vertex_ai", "gemini", "openai"] and
              String.starts_with?(Enum.at(components, 1), "v")

          length(components) == 2 ->
            Enum.at(components, 0) in ["vertex_ai", "gemini", "openai"] or
              String.starts_with?(Enum.at(components, 0), "v")

          true ->
            false
        end
      end
    end
  end

  defp parse_model(model, api_type) do
    if not validate_model_string(model) do
      {:error, :invalid_format}
    else
      parts = String.split(model, "/")

      {model_id, api_version, default_backend, is_vertexai} =
        cond do
          # Try matching OpenAI prefix
          length(parts) >= 3 and Enum.at(parts, 1) == "openai" ->
            if length(parts) > 3 and Enum.at(parts, 2) == "v1" do
              {Enum.join(Enum.slice(parts, 3..-1//1), "/"), "v1", ADK.LLM.OpenAI, false}
            else
              {Enum.join(Enum.slice(parts, 2..-1//1), "/"), nil, ADK.LLM.OpenAI, false}
            end

          # Try matching Vertex AI prefix
          length(parts) >= 3 and Enum.at(parts, 1) == "vertex_ai" ->
            if length(parts) > 3 and Enum.at(parts, 2) == "v1beta" do
              {Enum.join(Enum.slice(parts, 3..-1//1), "/"), "v1beta", ADK.LLM.Gemini, true}
            else
              {Enum.join(Enum.slice(parts, 2..-1//1), "/"), nil, ADK.LLM.Gemini, true}
            end

          # Try matching Gemini prefix
          length(parts) >= 3 and Enum.at(parts, 1) == "gemini" ->
            if length(parts) > 3 and Enum.at(parts, 2) == "v1" do
              {Enum.join(Enum.slice(parts, 3..-1//1), "/"), "v1", ADK.LLM.Gemini, false}
            else
              {Enum.join(Enum.slice(parts, 2..-1//1), "/"), nil, ADK.LLM.Gemini, false}
            end

          true ->
            # Fallback
            use_vertexai_env = String.downcase(System.get_env("GOOGLE_GENAI_USE_VERTEXAI") || "")
            is_vertex = use_vertexai_env in ["true", "1"]

            if length(parts) >= 3 and Enum.at(parts, 1) in ["v1", "v1beta"] do
              {Enum.join(Enum.slice(parts, 2..-1//1), "/"), Enum.at(parts, 1), ADK.LLM.Gemini,
               is_vertex}
            else
              {Enum.join(Enum.slice(parts, 1..-1//1), "/"), nil, ADK.LLM.Gemini, is_vertex}
            end
        end

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

  defp build_base_url(proxy_url, is_vertexai, api_version, backend) do
    proxy_url = String.trim_trailing(proxy_url || "", "/")

    if backend == ADK.LLM.OpenAI do
      version = api_version || "v1"
      "#{proxy_url}/#{version}"
    else
      if is_vertexai do
        version = api_version || "v1beta"
        project = System.get_env("GOOGLE_CLOUD_PROJECT")
        location = System.get_env("GOOGLE_CLOUD_LOCATION")

        "#{proxy_url}/#{version}/projects/#{project}/locations/#{location}/publishers/google/models"
      else
        version = api_version || "v1beta"
        "#{proxy_url}/#{version}/models"
      end
    end
  end
end
