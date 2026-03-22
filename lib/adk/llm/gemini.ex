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
      ADK.LLM.Gemini.generate("gemini-flash-latest", %{
        instruction: "You are helpful.",
        messages: [%{role: :user, parts: [%{text: "Hello"}]}]
      })
  """

  @behaviour ADK.LLM

  @base_url "https://generativelanguage.googleapis.com/v1beta/models"
  @default_model "gemini-flash-latest"

  @impl true
  @spec generate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate(model, request) do
    model = if model in [nil, ""], do: @default_model, else: model

    case auth() do
      {:api_key, key} -> do_generate(model, {:api_key, key}, request)
      {:bearer, token} -> do_generate(model, {:bearer, token}, request)
      {:error, _} = err -> err
    end
  end

  defp do_generate(model, auth, request) do
    url = "#{@base_url}/#{model}:generateContent"
    body = build_request_body(request)

    req_options = [url: url, json: body]

    req_options =
      case auth do
        {:api_key, key} -> req_options ++ [params: [key: key]]
        {:bearer, token} -> req_options ++ [headers: [{"authorization", "Bearer #{token}"}]]
      end

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
        nil ->
          body

        [] ->
          body

        tools ->
          {builtins, fn_tools} = Enum.split_with(tools, &Map.has_key?(&1, :__builtin__))

          tool_entries =
            if fn_tools == [] do
              []
            else
              [%{function_declarations: format_tools(fn_tools)}]
            end

          tool_entries =
            Enum.reduce(builtins, tool_entries, fn
              %{__builtin__: :google_search}, acc -> acc ++ [%{google_search: %{}}]
              %{__builtin__: :code_execution}, acc -> acc ++ [%{code_execution: %{}}]
              _, acc -> acc
            end)

          if tool_entries == [] do
            body
          else
            Map.put(body, :tools, tool_entries)
          end
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

    # Apply safety settings if provided in generate_config
    body =
      case Map.get(request, :generate_config) do
        %{safety_settings: settings} when is_list(settings) and settings != [] ->
          Map.put(body, :safetySettings, settings)

        _ ->
          body
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

  defp format_part(%{function_call: %{name: name, args: args}} = part) do
    fc = %{name: name, args: args}
    fc = if Map.has_key?(part.function_call, :thought_signature) do
      Map.put(fc, :thought_signature, part.function_call.thought_signature)
    else
      fc
    end
    %{functionCall: fc}
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

  defp parse_response_part(%{"functionCall" => fc}) do
    base = %{name: Map.get(fc, "name"), args: Map.get(fc, "args")}
    base = if Map.has_key?(fc, "thought_signature") do
      Map.put(base, :thought_signature, fc["thought_signature"])
    else
      base
    end
    %{function_call: base}
  end

  # Code execution response parts
  defp parse_response_part(%{"executableCode" => %{"language" => lang, "code" => code}}) do
    %{executable_code: %{language: lang, code: code}}
  end

  defp parse_response_part(%{"codeExecutionResult" => %{"outcome" => outcome, "output" => output}}) do
    %{code_execution_result: %{outcome: outcome, output: output}}
  end

  defp parse_response_part(%{"codeExecutionResult" => %{"outcome" => outcome}}) do
    %{code_execution_result: %{outcome: outcome, output: ""}}
  end

  defp parse_response_part(other), do: other

  defp auth do
    case Application.get_env(:adk, :gemini_api_key) do
      nil ->
        case System.get_env("GEMINI_API_KEY") do
          nil ->
            case Application.get_env(:adk, :gemini_bearer_token) do
              nil ->
                case System.get_env("GEMINI_BEARER_TOKEN") do
                  nil -> {:error, :missing_api_key}
                  token -> {:bearer, token}
                end

              token ->
                {:bearer, token}
            end

          key ->
            {:api_key, key}
        end

      key ->
        {:api_key, key}
    end
  end

  # api_key/0 removed — use auth/0 instead
end
