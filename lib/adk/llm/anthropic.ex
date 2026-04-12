defmodule ADK.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude LLM backend using the Messages API via Req.

  ## Authentication

  Supports two auth modes, checked in this order:

  ### OAuth Token (Claude Code CLI / Claude Pro)

  Uses `Authorization: Bearer` header. Sources checked in order:

      # Application config
      config :adk, :anthropic_oauth_token, "sk-ant-sid02-..."

      # Environment variable
      ANTHROPIC_OAUTH_TOKEN=sk-ant-sid02-...

      # Auto-detected from Claude Code CLI session
      CLAUDE_AI_SESSION_KEY=sk-ant-sid02-...

  ### API Key

  Uses `x-api-key` header. Sources checked in order:

      # Application config
      config :adk, :anthropic_api_key, "sk-ant-api03-..."

      # Environment variable
      ANTHROPIC_API_KEY=sk-ant-api03-...

  ## Usage

      config :adk, :llm_backend, ADK.LLM.Anthropic

      ADK.LLM.Anthropic.generate("claude-sonnet-4-20250514", %{
        instruction: "You are helpful.",
        messages: [%{role: :user, parts: [%{text: "Hello"}]}]
      })
  """

  @behaviour ADK.LLM

  @base_url "https://api.anthropic.com/v1"
  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 4096
  @anthropic_version "2023-06-01"

  @impl true
  @spec generate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate(model, request) do
    model = if model in [nil, ""], do: @default_model, else: model

    case resolve_auth() do
      {:ok, auth} -> do_generate(model, auth, request)
      {:error, _} = err -> err
    end
  end

  defp do_generate(model, auth, request) do
    url = "#{@base_url}/messages"
    body = build_request_body(model, request)

    req_options = [
      url: url,
      json: body,
      headers: auth_headers(auth)
    ]

    req_options =
      req_options ++
        [receive_timeout: 30_000, connect_options: [timeout: 10_000]] ++
        req_test_options()

    # NOTE: Do NOT wrap in ADK.LLM.Retry here — ADK.LLM.generate/3 already
    # applies retry logic around the backend call.
    case Req.post(Req.new(req_options)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %Req.Response{status: 429} = resp} ->
        retry_ms = ADK.LLM.Retry.extract_retry_after(resp)
        {:retry_after, retry_ms, :rate_limited}

      {:ok, %Req.Response{status: 529} = resp} ->
        retry_ms = ADK.LLM.Retry.extract_retry_after(resp)
        {:retry_after, retry_ms, :overloaded}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp req_test_options do
    if ADK.Config.anthropic_test_plug() do
      [plug: {Req.Test, ADK.LLM.Anthropic}]
    else
      []
    end
  end

  defp build_request_body(model, request) do
    max_tokens = Map.get(request, :max_tokens, @default_max_tokens)
    messages = build_messages(request)

    body = %{model: model, max_tokens: max_tokens, messages: messages}

    # System goes as top-level param, not in messages
    body =
      case Map.get(request, :instruction) do
        nil -> body
        "" -> body
        inst -> Map.put(body, :system, inst)
      end

    body =
      case Map.get(request, :tools) do
        nil -> body
        [] -> body
        tools -> Map.put(body, :tools, format_tools(tools))
      end

    body =
      case Map.get(request, :tool_choice) do
        nil -> body
        choice -> Map.put(body, :tool_choice, format_tool_choice(choice))
      end

    # Metadata (user_id for abuse tracking)
    body =
      case Map.get(request, :metadata) do
        nil -> body
        meta when meta == %{} -> body
        meta -> Map.put(body, :metadata, meta)
      end

    # Apply generate_config
    case Map.get(request, :generate_config) do
      nil ->
        body

      config when config == %{} ->
        body

      config ->
        gen_config =
          [
            {:temperature, config[:temperature]},
            {:top_p, config[:top_p]},
            {:top_k, config[:top_k]},
            {:stop_sequences, config[:stop_sequences]}
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        body = Map.merge(body, gen_config)

        case config[:max_output_tokens] do
          nil -> body
          max -> %{body | max_tokens: max}
        end
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp build_messages(request) do
    request
    |> Map.get(:messages, [])
    |> Enum.map(&format_message/1)
  end

  defp format_message(%{role: role, parts: parts}) do
    responses = for %{function_response: fr} <- parts, do: fr
    calls = for %{function_call: fc} <- parts, do: fc

    cond do
      responses != [] ->
        %{
          role: "user",
          content: Enum.map(responses, &format_function_response/1)
        }

      calls != [] ->
        content =
          parts
          |> Enum.map(fn
            %{text: t} -> %{type: "text", text: t}
            %{function_call: fc} -> format_function_call(fc)
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        %{role: "assistant", content: content}

      true ->
        role_str = map_role(role)

        content =
          parts
          |> Enum.map(&format_part(&1, role_str))
          |> Enum.reject(&is_nil/1)

        # To maintain exact previous behavior for simple text where possible,
        # if it's just one text block, we can leave it as a string, but Anthropic
        # prefers arrays or strings. Let's just use the array.
        # Wait, Python sends array of blocks. We will too.
        if Enum.all?(content, &is_binary/1) do
          %{role: role_str, content: Enum.join(content, "\n")}
        else
          %{role: role_str, content: content}
        end
    end
  end

  defp format_function_response(%{name: name, response: resp} = fr) do
    # tool_use_id resolution order:
    # 1. :id on the function_response (preserved from tool_use block by agent loop)
    # 2. :tool_call_id in the response map (legacy path)
    # 3. tool name as fallback (generates a new id)
    id_from_resp =
      Map.get(fr, :id) ||
        Map.get(resp, :tool_call_id, Map.get(resp, "tool_call_id", nil)) ||
        generate_tool_use_id(name)

    content = extract_tool_result_content(resp)

    result = %{
      type: "tool_result",
      tool_use_id: id_from_resp,
      content: content
    }

    # Propagate is_error flag when the tool execution failed
    case Map.get(fr, :is_error, Map.get(resp, :is_error, Map.get(resp, "is_error"))) do
      true -> Map.put(result, :is_error, true)
      _ -> result
    end
  end

  defp extract_tool_result_content(resp) do
    resp_clean = Map.drop(resp, [:tool_call_id, "tool_call_id"])

    cond do
      # If it has "content" as a list
      Map.has_key?(resp_clean, :content) and is_list(resp_clean.content) ->
        resp_clean.content
        |> Enum.map(fn
          %{type: "text", text: t} -> t
          %{"type" => "text", "text" => t} -> t
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      Map.has_key?(resp_clean, "content") and is_list(resp_clean["content"]) ->
        resp_clean["content"]
        |> Enum.map(fn
          %{type: "text", text: t} -> t
          %{"type" => "text", "text" => t} -> t
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      # If it has "result"
      Map.has_key?(resp_clean, :result) ->
        serialize_tool_result(resp_clean.result)

      Map.has_key?(resp_clean, "result") ->
        serialize_tool_result(resp_clean["result"])

      # Otherwise, the whole thing
      true ->
        serialize_tool_result(resp_clean)
    end
  end

  defp serialize_tool_result(val) when is_binary(val), do: val
  defp serialize_tool_result(val), do: Jason.encode!(val)

  defp format_function_call(%{name: name, args: args} = fc) do
    id =
      Map.get(fc, :id) ||
        Map.get(args, :tool_call_id) ||
        Map.get(args, "tool_call_id") ||
        generate_tool_use_id(name)

    %{
      type: "tool_use",
      id: id,
      name: name,
      input: Map.drop(args, [:tool_call_id, "tool_call_id"])
    }
  end

  defp generate_tool_use_id(name) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "toolu_#{name}_#{suffix}"
  end

  defp format_part(%{text: t}, _role), do: %{type: "text", text: t}

  defp format_part(%{inline_data: %{mime_type: mime, data: data}}, role) do
    if role == "assistant" do
      require Logger

      cond do
        String.starts_with?(mime, "image/") ->
          Logger.warning("Image data is not supported in Claude for assistant turns.")

        String.starts_with?(mime, "application/pdf") ->
          Logger.warning("PDF data is not supported in Claude for assistant turns.")

        true ->
          Logger.warning("Media data is not supported in Claude for assistant turns.")
      end

      nil
    else
      cond do
        String.starts_with?(mime, "image/") ->
          %{
            type: "image",
            source: %{
              type: "base64",
              media_type: mime,
              data: data
            }
          }

        String.starts_with?(mime, "application/pdf") ->
          %{
            type: "document",
            source: %{
              type: "base64",
              media_type: mime,
              data: data
            }
          }

        true ->
          nil
      end
    end
  end

  defp format_part(_, _), do: nil

  defp map_role(:user), do: "user"
  defp map_role(:model), do: "assistant"
  defp map_role(:assistant), do: "assistant"
  defp map_role(role) when is_binary(role), do: role
  defp map_role(role), do: to_string(role)

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      t = %{name: tool.name, description: Map.get(tool, :description, "")}

      case Map.get(tool, :parameters) do
        nil -> Map.put(t, :input_schema, %{type: "object"})
        params -> Map.put(t, :input_schema, params)
      end
    end)
  end

  defp format_tool_choice(:auto), do: %{type: "auto"}
  defp format_tool_choice("auto"), do: %{type: "auto"}
  defp format_tool_choice(:any), do: %{type: "any"}
  defp format_tool_choice("any"), do: %{type: "any"}
  defp format_tool_choice(:none), do: %{type: "none"}
  defp format_tool_choice("none"), do: %{type: "none"}

  defp format_tool_choice(%{type: "tool", name: name}),
    do: %{type: "tool", name: name}

  defp format_tool_choice({:tool, name}),
    do: %{type: "tool", name: name}

  # Pass through if already a map in the right format
  defp format_tool_choice(%{type: _} = choice), do: choice

  # --- Response parsing ---

  defp parse_response(%{"content" => content} = body) do
    %{
      content: parse_content(content),
      usage_metadata: Map.get(body, "usage"),
      stop_reason: parse_stop_reason(Map.get(body, "stop_reason")),
      model: Map.get(body, "model"),
      id: Map.get(body, "id")
    }
  end

  defp parse_response(body) do
    %{
      content: %{role: :model, parts: [%{text: ""}]},
      usage_metadata: Map.get(body, "usage"),
      stop_reason: parse_stop_reason(Map.get(body, "stop_reason")),
      model: Map.get(body, "model"),
      id: Map.get(body, "id")
    }
  end

  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason("stop_sequence"), do: :stop_sequence
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason(_), do: nil

  defp parse_content(blocks) when is_list(blocks) do
    parts = Enum.map(blocks, &parse_block/1)
    %{role: :model, parts: parts}
  end

  defp parse_block(%{"type" => "text", "text" => text}), do: %{text: text}

  defp parse_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{function_call: %{name: name, args: input, id: id}}
  end

  defp parse_block(%{"type" => "thinking", "thinking" => thinking}) do
    %{thinking: thinking}
  end

  defp parse_block(other), do: other

  # --- Auth resolution ---
  # Supports two auth modes:
  # 1. OAuth token (from Claude Code CLI) — uses Authorization: Bearer header
  # 2. API key — uses x-api-key header
  #
  # OAuth token sources (checked in order):
  # - Application config :anthropic_oauth_token
  # - ANTHROPIC_OAUTH_TOKEN env var
  # - Claude Code CLI's ~/.claude.json (oauthAccount + session key)
  #
  # API key sources (checked in order):
  # - Application config :anthropic_api_key
  # - ANTHROPIC_API_KEY env var

  @type auth :: {:oauth, String.t()} | {:api_key, String.t()}

  @doc false
  @spec resolve_auth() :: {:ok, auth()} | {:error, :missing_credentials}
  def resolve_auth do
    with :skip <- check_oauth(),
         :skip <- check_claude_code_session(),
         :skip <- check_api_key() do
      # Return :missing_api_key for backward compatibility
      {:error, :missing_api_key}
    end
  end

  defp check_oauth do
    case ADK.Config.anthropic_oauth_token() do
      nil -> :skip
      "" -> :skip
      token -> {:ok, {:oauth, token}}
    end
  end

  defp check_claude_code_session do
    # Check CLAUDE_AI_SESSION_KEY env var (set by Claude Code CLI)
    # Only when auto-discovery is enabled (default: false — opt-in)
    if ADK.Config.anthropic_auto_discover() do
      case ADK.Config.claude_ai_session_key() do
        nil -> :skip
        "" -> :skip
        key -> {:ok, {:oauth, key}}
      end
    else
      :skip
    end
  end

  defp check_api_key do
    case ADK.Config.anthropic_api_key() do
      nil -> :skip
      "" -> :skip
      key -> {:ok, {:api_key, key}}
    end
  end

  # OAuth headers for Claude Code tokens (sk-ant-oat01-*).
  # NOTE: When using OAuth, the system instruction MUST start with
  # "You are Claude Code, Anthropic's official CLI for Claude."
  # This is an API requirement — the caller is responsible for ensuring it.
  defp auth_headers({:oauth, token}) do
    [
      {"authorization", "Bearer #{token}"},
      {"anthropic-version", @anthropic_version},
      {"anthropic-beta", "claude-code-20250219,oauth-2025-04-20"},
      {"user-agent", "claude-cli/2.1.2 (external, cli)"},
      {"x-app", "cli"}
    ]
  end

  defp auth_headers({:api_key, key}) do
    [
      {"x-api-key", key},
      {"anthropic-version", @anthropic_version}
    ]
  end
end
