defmodule ADK.LLM.Gemini do
  @moduledoc """
  Gemini LLM backend using the REST API via Req.

  ## Configuration

      # config/config.exs
      config :adk, :gemini_api_key, "your-api-key"

      # Or via environment variable
      GEMINI_API_KEY=your-api-key

  ## Usage

      config :adk, :llm_backend, ADK.LLM.Gemini

      # Or call directly
      ADK.LLM.Gemini.generate("gemini-2.0-flash", %{
        instruction: "You are helpful.",
        messages: [%{role: :user, parts: [%{text: "Hello"}]}]
      })
  """

  @behaviour ADK.LLM

  @base_url "https://generativelanguage.googleapis.com/v1beta/models"
  @default_model "gemini-2.0-flash"

  @impl true
  def generate(model, request) do
    model = if model in [nil, ""], do: @default_model, else: model

    case api_key() do
      {:ok, key} -> do_generate(model, key, request)
      {:error, _} = err -> err
    end
  end

  defp do_generate(model, api_key, request) do
    url = "#{@base_url}/#{model}:generateContent"
    body = build_request_body(request)

    req_options = [url: url, params: [key: api_key], json: body]
    req_options = req_options ++ req_test_options()

    case Req.post(Req.new(req_options)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp req_test_options do
    if Application.get_env(:adk, :gemini_test_plug) do
      [plug: {Req.Test, ADK.LLM.Gemini}]
    else
      []
    end
  end

  defp build_request_body(request) do
    body = %{}

    body =
      case Map.get(request, :instruction) do
        nil -> body
        "" -> body
        inst -> Map.put(body, :system_instruction, %{parts: [%{text: inst}]})
      end

    body =
      case Map.get(request, :messages) do
        nil -> body
        msgs -> Map.put(body, :contents, Enum.map(msgs, &format_content/1))
      end

    body =
      case Map.get(request, :tools) do
        nil -> body
        [] -> body
        tools -> Map.put(body, :tools, [%{function_declarations: format_tools(tools)}])
      end

    # Apply generate_config as generationConfig
    body =
      case Map.get(request, :generate_config) do
        nil -> body
        config when config == %{} -> body
        config ->
          gen_config = %{}
          gen_config = put_if(gen_config, :temperature, config[:temperature])
          gen_config = put_if(gen_config, :topP, config[:top_p])
          gen_config = put_if(gen_config, :topK, config[:top_k])
          gen_config = put_if(gen_config, :maxOutputTokens, config[:max_output_tokens])
          gen_config = put_if(gen_config, :stopSequences, config[:stop_sequences])
          gen_config = put_if(gen_config, :candidateCount, config[:candidate_count])
          gen_config = put_if(gen_config, :responseMimeType, config[:response_mime_type])
          gen_config = put_if(gen_config, :responseSchema, config[:response_schema])
          if gen_config == %{}, do: body, else: Map.put(body, :generationConfig, gen_config)
      end

    body
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp format_content(%{role: role, parts: parts}) do
    %{
      role: to_string(role),
      parts: Enum.map(parts, &format_part/1)
    }
  end

  defp format_part(%{text: text}), do: %{text: text}

  defp format_part(%{function_call: %{name: name, args: args}}) do
    %{functionCall: %{name: name, args: args}}
  end

  defp format_part(%{function_response: %{name: name, response: resp}}) do
    %{functionResponse: %{name: name, response: resp}}
  end

  defp format_part(other), do: other

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      decl = %{name: tool.name, description: Map.get(tool, :description, "")}

      case Map.get(tool, :parameters) do
        nil -> decl
        params -> Map.put(decl, :parameters, params)
      end
    end)
  end

  defp parse_response(%{"candidates" => [%{"content" => content} | _]} = body) do
    %{
      content: parse_content(content),
      usage_metadata: Map.get(body, "usageMetadata")
    }
  end

  defp parse_response(body) do
    %{
      content: %{role: :model, parts: [%{text: ""}]},
      usage_metadata: Map.get(body, "usageMetadata")
    }
  end

  defp parse_content(%{"role" => _role, "parts" => parts}) do
    %{
      role: :model,
      parts: Enum.map(parts, &parse_response_part/1)
    }
  end

  defp parse_response_part(%{"text" => text}), do: %{text: text}

  defp parse_response_part(%{"functionCall" => %{"name" => name, "args" => args}}) do
    %{function_call: %{name: name, args: args}}
  end

  defp parse_response_part(other), do: other

  defp api_key do
    case Application.get_env(:adk, :gemini_api_key) do
      nil ->
        case System.get_env("GEMINI_API_KEY") do
          nil -> {:error, :missing_api_key}
          key -> {:ok, key}
        end

      key ->
        {:ok, key}
    end
  end
end
