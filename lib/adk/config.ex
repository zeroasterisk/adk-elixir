defmodule ADK.Config do
  @moduledoc """
  Centralized configuration access for ADK.
  """

  @app :adk

  @doc """
  Returns a configuration value for the given key.
  """
  def get(key, default \\ nil) do
    Application.get_env(@app, key, default)
  end

  @doc """
  Returns whether to start the credential store.
  """
  def start_credential_store?, do: get(:start_credential_store, true)

  @doc """
  Returns whether to start the artifact store.
  """
  def start_artifact_store?, do: get(:start_artifact_store, true)

  @doc """
  Returns whether to start the memory store.
  """
  def start_memory_store?, do: get(:start_memory_store, true)

  @doc """
  Returns whether to start the approval server.
  """
  def start_approval_server?, do: get(:start_approval_server, false)

  @doc """
  Returns whether to start the circuit breaker.
  """
  def start_circuit_breaker?, do: get(:start_circuit_breaker, true)

  @doc """
  Returns whether to start the LLM router.
  """
  def start_llm_router?, do: get(:start_llm_router, true)

  @doc """
  Returns the MCP session manager module.
  """
  def mcp_session_manager_mod do
    get(:mcp_session_manager_mod, ADK.Agents.SessionManagerImpl)
  end

  @doc """
  Returns the circuit breaker configuration.
  """
  def circuit_breaker do
    get(:circuit_breaker, [])
  end

  @doc """
  Returns the LLM backend.
  """
  def llm_backend do
    get(:llm_backend, ADK.LLM.Mock)
  end

  @doc """
  Returns the LLM router configuration.
  """
  def llm_router do
    get(:llm_router, [])
  end

  @doc """
  Returns the auth providers configuration.
  """
  def auth_providers do
    get(:auth_providers, %{})
  end

  @doc """
  Returns the auth exchangers configuration.
  """
  def auth_exchangers do
    get(:auth_exchangers, %{})
  end

  @doc """
  Returns the auth refreshers configuration.
  """
  def auth_refreshers do
    get(:auth_refreshers, %{})
  end

  @doc """
  Returns the feature overrides.
  """
  def feature_overrides do
    get(:feature_overrides, %{})
  end

  @doc """
  Returns the Anthropic configuration.
  """
  def anthropic_api_key, do: get(:anthropic_api_key, System.get_env("ANTHROPIC_API_KEY"))
  def anthropic_oauth_token, do: get(:anthropic_oauth_token, System.get_env("ANTHROPIC_OAUTH_TOKEN"))
  def anthropic_auto_discover, do: get(:anthropic_auto_discover, false)
  def anthropic_test_plug, do: get(:anthropic_test_plug)
  def claude_ai_session_key, do: get(:claude_ai_session_key, System.get_env("CLAUDE_AI_SESSION_KEY"))

  @doc """
  Returns the Gemini configuration.
  """
  def gemini_api_key, do: get(:gemini_api_key, System.get_env("GEMINI_API_KEY"))
  def gemini_bearer_token, do: get(:gemini_bearer_token, System.get_env("GEMINI_BEARER_TOKEN"))
  def gemini_base_url, do: get(:gemini_base_url, System.get_env("GEMINI_BASE_URL"))
  def gemini_test_plug, do: get(:gemini_test_plug)

  @doc """
  Returns the OpenAI configuration.
  """
  def openai_api_key, do: get(:openai_api_key, System.get_env("OPENAI_API_KEY"))
  def openai_base_url, do: get(:openai_base_url, System.get_env("OPENAI_BASE_URL"))
  def openai_test_plug, do: get(:openai_test_plug)

  @doc """
  Returns the Google Cloud / Vertex AI configuration.
  """
  def google_cloud_project do
    get(:google_cloud_project) ||
      get(:vertex_project_id) ||
      System.get_env("GOOGLE_CLOUD_PROJECT") ||
      System.get_env("GCLOUD_PROJECT")
  end

  def google_cloud_location do
    get(:google_cloud_location) ||
      get(:vertex_location) ||
      System.get_env("GOOGLE_CLOUD_LOCATION")
  end

  def google_application_credentials do
    get(:google_application_credentials) ||
      get(:vertex_credentials_file) ||
      System.get_env("GOOGLE_APPLICATION_CREDENTIALS")
  end

  def vertex_project_id, do: google_cloud_project()
  def vertex_location, do: google_cloud_location()
  def vertex_credentials_file, do: google_application_credentials()
  def vertex_reasoning_engine_id, do: get(:vertex_reasoning_engine_id)
  def vertex_api_key, do: get(:vertex_api_key)
  def vertex_memory_test_plug, do: get(:vertex_memory_test_plug)
  def vertex_session_test_plug, do: get(:vertex_session_test_plug)

  @doc """
  Returns the Apigee configuration.
  """
  def apigee_proxy_url, do: get(:apigee_proxy_url, System.get_env("APIGEE_PROXY_URL"))

  @doc """
  Returns whether to use Vertex AI for Gemini.
  """
  def google_genai_use_vertexai do
    val = get(:google_genai_use_vertexai) || System.get_env("GOOGLE_GENAI_USE_VERTEXAI")
    case val do
      val when is_binary(val) -> String.downcase(val) == "true"
      val -> !!val
    end
  end

  @doc """
  Returns the GitHub configuration.
  """
  def github_token, do: get(:github_token, System.get_env("GITHUB_TOKEN"))

  @doc """
  Returns the OpenTelemetry configuration.
  """
  def otel_resource_attributes, do: get(:otel_resource_attributes, System.get_env("OTEL_RESOURCE_ATTRIBUTES"))
  def google_cloud_default_log_name, do: get(:google_cloud_default_log_name, System.get_env("GOOGLE_CLOUD_DEFAULT_LOG_NAME"))

  @doc """
  Returns the GCP access token.
  """
  def gcp_access_token, do: get(:gcp_access_token, System.get_env("GCP_ACCESS_TOKEN"))

  @doc """
  Returns the PubSub module.
  """
  def pubsub do
    get(:pubsub, ADK.PubSub)
  end

  @doc """
  Returns the JSON store path.
  """
  def json_store_path do
    get(:json_store_path, "priv/sessions")
  end

  @doc """
  Returns the span store TTL in milliseconds.
  """
  def span_store_ttl_ms(default) do
    get(:span_store_ttl_ms, default)
  end

  @doc """
  Returns the maximum tool result bytes.
  """
  def max_tool_result_bytes(default) do
    get(:max_tool_result_bytes, default)
  end

  @doc """
  Returns the Google Auth client.
  """
  def google_auth_client do
    get(:google_auth_client, ADK.Auth.Google.DefaultClient)
  end
end
