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

  require Logger

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
    base = Map.get(request, :base_url, System.get_env("GEMINI_BASE_URL") || @base_url)
    url = "#{base}/#{model}:generateContent"
    body = build_request_body(request)

    custom_headers = Map.get(request, :custom_headers, [])

    req_options = [url: url, json: body, headers: custom_headers]

    req_options =
      case auth do
        {:api_key, key} ->
          req_options ++ [params: [key: key]]

        {:bearer, token} ->
          update_in(req_options[:headers], &[{"authorization", "Bearer #{token}"} | &1])
      end

    req_options =
      req_options ++
        [receive_timeout: 30_000, connect_options: [timeout: 10_000]] ++
        req_test_options()

    # NOTE: Do NOT wrap in ADK.LLM.Retry here — ADK.LLM.generate/3 already
    # applies retry logic around the backend call. Double-wrapping caused
    # worst-case stalls of ~5 minutes (inner 3×30s × outer 3 retries).
    case Req.post(Req.new(req_options)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %Req.Response{status: 429} = resp} ->
        retry_ms = ADK.LLM.Retry.extract_retry_after(resp)
        if retry_ms, do: Logger.warning("[Gemini] Rate limited, retry-after: #{retry_ms}ms")
        {:retry_after, retry_ms, :rate_limited}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp req_test_options do
    if ADK.Config.gemini_test_plug() do
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

    # Apply toolConfig — tells Gemini to use structured function calling.
    # Without this, Gemini 2.5+ models may hallucinate tool calls in text
    # (e.g. <tool_code> blocks) instead of returning structured functionCall parts.
    # Matches the behaviour of the official Python/Go GenAI SDKs.
    body =
      if Map.has_key?(body, :tools) do
        tool_config =
          case Map.get(request, :tool_config) do
            nil -> %{functionCallingConfig: %{mode: "AUTO"}}
            config -> config
          end

        Map.put(body, :toolConfig, tool_config)
      else
        body
      end

    # Apply generate_config as generationConfig
    body =
      case Map.get(request, :generate_config) do
        nil ->
          body

        config when config == %{} ->
          body

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
          gen_config = put_if(gen_config, :responseJsonSchema, config[:response_json_schema])
          gen_config = put_if(gen_config, :presencePenalty, config[:presence_penalty])
          gen_config = put_if(gen_config, :frequencyPenalty, config[:frequency_penalty])
          gen_config = put_if(gen_config, :seed, config[:seed])
          gen_config = put_if(gen_config, :responseLogprobs, config[:response_logprobs])
          gen_config = put_if(gen_config, :logprobs, config[:logprobs])
          gen_config = put_if(gen_config, :responseModalities, config[:response_modalities])
          gen_config = put_if(gen_config, :thinkingConfig, config[:thinking_config])
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

  defp format_part(%{text: text} = part) do
    base = %{text: text}
    maybe_add_thought_signature(base, part)
  end

  defp format_part(%{function_call: %{name: name, args: args} = fc} = part) do
    fc_map = %{name: name, args: args}
    fc_map = if Map.has_key?(fc, :id), do: Map.put(fc_map, :id, fc.id), else: fc_map
    base = %{functionCall: fc_map}
    maybe_add_thought_signature(base, part)
  end

  defp format_part(%{function_response: %{name: name, response: resp}}) do
    %{functionResponse: %{name: name, response: resp}}
  end

  defp format_part(other), do: other

  # Gemini 2.5+/3 models return thoughtSignature in function_call and text parts.
  # These MUST be passed back in subsequent turns for function calling to work.
  defp maybe_add_thought_signature(base, part) do
    case Map.get(part, :thought_signature) do
      nil -> base
      sig -> Map.put(base, :thoughtSignature, sig)
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      decl = %{name: tool.name, description: Map.get(tool, :description, "")}

      case Map.get(tool, :parameters) do
        nil -> decl
        params -> Map.put(decl, :parameters, params)
      end
    end)
  end

  defp parse_response(%{"candidates" => [candidate | _]} = body) do
    content = Map.get(candidate, "content", %{})
    finish_reason = Map.get(candidate, "finishReason")

    if content == %{} or content == nil do
      finish_message = Map.get(candidate, "finishMessage", "")

      Logger.warning(
        "[Gemini] Empty content. finishReason=#{inspect(finish_reason)} finishMessage=#{inspect(finish_message)}"
      )
    end

    result = %{
      content: parse_content(content || %{}),
      usage_metadata: Map.get(body, "usageMetadata"),
      finish_reason: finish_reason
    }

    result = put_if(result, :prompt_feedback, Map.get(body, "promptFeedback"))
    put_if(result, :model_version, Map.get(body, "modelVersion"))
  end

  defp parse_response(body) do
    Logger.warning("[Gemini] No candidates in response: #{inspect(Map.keys(body || %{}))}")

    %{
      content: %{role: :model, parts: [%{text: ""}]},
      usage_metadata: Map.get(body, "usageMetadata"),
      finish_reason: nil
    }
  end

  defp parse_content(%{"role" => _role, "parts" => parts}) do
    %{
      role: :model,
      parts: Enum.map(parts, &parse_response_part/1)
    }
  end

  defp parse_content(%{"role" => _role}) do
    %{role: :model, parts: [%{text: ""}]}
  end

  defp parse_content(other) do
    Logger.warning("[Gemini] parse_content: unexpected shape: #{inspect(other)}")
    %{role: :model, parts: [%{text: ""}]}
  end

  defp parse_response_part(%{"text" => text} = part) do
    base = %{text: text}
    base = if part["thought"] == true, do: Map.put(base, :thought, true), else: base

    case part do
      %{"thoughtSignature" => sig} -> Map.put(base, :thought_signature, sig)
      _ -> base
    end
  end

  defp parse_response_part(%{"functionCall" => %{"name" => name} = fc} = part) do
    args = Map.get(fc, "args", %{})
    fc_map = %{name: name, args: args}
    fc_map = if Map.has_key?(fc, "id"), do: Map.put(fc_map, :id, fc["id"]), else: fc_map
    base = %{function_call: fc_map}

    case part do
      %{"thoughtSignature" => sig} -> Map.put(base, :thought_signature, sig)
      _ -> base
    end
  end

  # Code execution response parts
  defp parse_response_part(%{"executableCode" => %{"language" => lang, "code" => code}}) do
    %{executable_code: %{language: lang, code: code}}
  end

  defp parse_response_part(%{
         "codeExecutionResult" => %{"outcome" => outcome, "output" => output}
       }) do
    %{code_execution_result: %{outcome: outcome, output: output}}
  end

  defp parse_response_part(%{"codeExecutionResult" => %{"outcome" => outcome}}) do
    %{code_execution_result: %{outcome: outcome, output: ""}}
  end

  defp parse_response_part(other), do: other

  defp auth do
    cred = get_raw_credential()

    case ADK.Auth.CredentialManager.get_credential("gemini", cred) do
      {:ok, %{type: :api_key, api_key: nil}} -> {:error, :missing_api_key}
      {:ok, %{type: :api_key, api_key: key}} -> {:api_key, key}
      {:ok, %{access_token: token}} when is_binary(token) -> {:bearer, token}
      {:error, _} = err -> err
      :needs_auth -> {:error, :missing_api_key}
    end
  end

  defp get_raw_credential do
    use_vertex = System.get_env("GOOGLE_GENAI_USE_VERTEXAI") in ["true", "1"]

    cond do
      use_vertex ->
        load_vertex_credential()

      true ->
        load_api_key_credential()
    end
  end

  defp load_vertex_credential do
    case System.get_env("GOOGLE_APPLICATION_CREDENTIALS") do
      nil ->
        ADK.Auth.Credential.api_key(nil)

      path ->
        case File.read(path) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, key_info} ->
                ADK.Auth.Credential.service_account(key_info, scopes: ["https://www.googleapis.com/auth/cloud-platform"])
              {:error, _} ->
                ADK.Auth.Credential.api_key(nil)
            end
          {:error, _} ->
            ADK.Auth.Credential.api_key(nil)
        end
    end
  end

  defp load_api_key_credential do
    cond do
      key = ADK.Config.gemini_api_key() ->
        ADK.Auth.Credential.api_key(key)

      key = System.get_env("GOOGLE_API_KEY") ->
        ADK.Auth.Credential.api_key(key)

      key = System.get_env("GEMINI_API_KEY") ->
        ADK.Auth.Credential.api_key(key)

      token = ADK.Config.gemini_bearer_token() ->
        ADK.Auth.Credential.http_bearer(token)

      token = System.get_env("GEMINI_BEARER_TOKEN") ->
        ADK.Auth.Credential.http_bearer(token)

      true ->
        ADK.Auth.Credential.api_key(nil)
    end
  end

  # api_key/0 removed — use auth/0 instead
end
