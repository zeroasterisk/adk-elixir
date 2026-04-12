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
  def anthropic_api_key, do: get(:anthropic_api_key)
  def anthropic_oauth_token, do: get(:anthropic_oauth_token)
  def anthropic_auto_discover, do: get(:anthropic_auto_discover, false)
  def anthropic_test_plug, do: get(:anthropic_test_plug)

  @doc """
  Returns the Gemini configuration.
  """
  def gemini_api_key, do: get(:gemini_api_key)
  def gemini_bearer_token, do: get(:gemini_bearer_token)
  def gemini_test_plug, do: get(:gemini_test_plug)

  @doc """
  Returns the OpenAI configuration.
  """
  def openai_api_key, do: get(:openai_api_key)
  def openai_base_url, do: get(:openai_base_url)
  def openai_test_plug, do: get(:openai_test_plug)

  @doc """
  Returns the Vertex AI configuration.
  """
  def vertex_project_id, do: get(:vertex_project_id)
  def vertex_location, do: get(:vertex_location)
  def vertex_reasoning_engine_id, do: get(:vertex_reasoning_engine_id)
  def vertex_credentials_file, do: get(:vertex_credentials_file)
  def vertex_api_key, do: get(:vertex_api_key)
  def vertex_memory_test_plug, do: get(:vertex_memory_test_plug)
  def vertex_session_test_plug, do: get(:vertex_session_test_plug)

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
