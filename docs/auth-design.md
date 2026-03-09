# ADK Elixir — Auth & Credential Service Design

> **Date:** 2026-03-09
> **Status:** Proposal
> **Python ADK Reference:** `src/google/adk/auth/` (google/adk-python main)

---

## 1. Python ADK Auth Architecture Analysis

### 1.1 Core Components

The Python ADK auth system has **6 layers**:

| Layer | Module | Purpose |
|-------|--------|---------|
| **Data Models** | `auth_credential.py` | Structs for credentials (API key, HTTP, OAuth2, Service Account, OIDC) |
| **Auth Schemes** | `auth_schemes.py` | OpenAPI 3.0 security scheme types + OIDC extension |
| **Auth Config** | `auth_tool.py` | `AuthConfig` bundles scheme + raw credential + exchanged credential + credential_key |
| **Credential Service** | `credential_service/` | `BaseCredentialService` ABC for load/save credentials (scoped per app+user) |
| **Credential Manager** | `credential_manager.py` | Orchestrates the full credential lifecycle: validate → load → exchange → refresh → save |
| **Exchangers/Refreshers** | `exchanger/`, `refresher/` | Strategy pattern for credential exchange (auth code → tokens) and refresh (expired → new) |

Supporting modules:
- **`auth_handler.py`** — Legacy handler for OAuth URI generation and token exchange (pre-CredentialManager)
- **`auth_preprocessor.py`** — LLM request processor that intercepts `adk_request_credential` function call responses, stores credentials, and re-executes the original tool calls
- **`oauth2_credential_util.py`** — Shared helpers for creating OAuth2 sessions and updating tokens
- **`oauth2_discovery.py`** — RFC 8414 / RFC 9728 discovery for OAuth2 authorization server metadata

### 1.2 Credential Types

```
AuthCredentialTypes:
  API_KEY        → api_key field (string)
  HTTP           → HttpAuth (scheme + HttpCredentials with username/password/token)
  OAUTH2         → OAuth2Auth (client_id, client_secret, tokens, auth_uri, etc.)
  OPEN_ID_CONNECT → Same as OAuth2 but with OIDC discovery
  SERVICE_ACCOUNT → ServiceAccount (GCP service account JSON key or ADC)
```

### 1.3 Credential Scoping

Credentials are scoped by **app_name + user_id** (from `InvocationContext`). The `credential_key` is derived from a stable hash of `auth_scheme + raw_auth_credential` (minus volatile fields like tokens). This means:
- Same tool with same OAuth config → same credential_key → credential reuse across sessions
- Different users → different credential buckets
- Users can also specify `credential_key` explicitly

### 1.4 Credential Lifecycle (CredentialManager.get_auth_credential)

```
1. Validate credential config
2. If simple type (API_KEY, HTTP) → return immediately
3. Try load from CredentialService (persistent store)
4. If not found, try load from auth response (session state, temp: prefix)
5. If still not found:
   - Client credentials flow → use raw credentials directly
   - Auth code flow → return None (triggers user auth request)
6. Exchange if needed (auth_code → access_token, service_account → token)
7. Refresh if expired (using refresh_token)
8. Save if modified
```

### 1.5 Auth Request Flow (End-User Credential)

When a tool needs user auth:
1. Tool calls `context.request_credential(auth_config)` 
2. This generates an `adk_request_credential` function call to the LLM/client
3. Client handles OAuth redirect, collects auth response
4. Client sends back function response with auth credentials
5. `AuthPreprocessor` intercepts this, stores credential, re-executes original tool

### 1.6 Credential Service Implementations

| Implementation | Storage | Scoping |
|---|---|---|
| `InMemoryCredentialService` | Dict in process memory | `{app_name: {user_id: {key: credential}}}` |
| `SessionStateCredentialService` | Session state dict | `state[credential_key]` (⚠️ security warning) |

---

## 2. Proposed Elixir Module Design

### 2.1 Module Hierarchy

```
lib/adk/auth/
├── credential.ex            # AuthCredential struct + types
├── credential_type.ex       # Enum-like module for credential types
├── auth_scheme.ex           # Auth scheme types (OpenAPI security schemes)
├── auth_config.ex           # AuthConfig struct
├── credential_service.ex    # @behaviour for credential persistence
├── credential_manager.ex    # Orchestrator (stateless module)
├── credential_exchanger.ex  # @behaviour for credential exchange
├── credential_refresher.ex  # @behaviour for credential refresh
├── oauth2.ex                # OAuth2 helpers (session, token update, discovery)
├── auth_handler.ex          # OAuth URI generation + token exchange
├── auth_preprocessor.ex     # LLM request preprocessing for auth responses
│
├── credential_services/
│   ├── in_memory.ex         # ETS-backed credential store
│   ├── session_state.ex     # Session state-backed store
│   └── ecto.ex              # Database-backed store (Ecto)
│
├── exchangers/
│   ├── oauth2.ex            # OAuth2 auth_code → token exchange
│   └── service_account.ex   # GCP service account → access token
│
└── refreshers/
    └── oauth2.ex            # OAuth2 token refresh
```

### 2.2 Core Structs

```elixir
defmodule ADK.Auth.Credential do
  @moduledoc "Represents an authentication credential."

  @type credential_type ::
    :api_key | :http | :oauth2 | :open_id_connect | :service_account

  @type t :: %__MODULE__{
    auth_type: credential_type(),
    api_key: String.t() | nil,
    http: http_auth() | nil,
    oauth2: oauth2_auth() | nil,
    service_account: service_account() | nil,
    resource_ref: String.t() | nil
  }

  @type http_credentials :: %{
    username: String.t() | nil,
    password: String.t() | nil,
    token: String.t() | nil
  }

  @type http_auth :: %{
    scheme: String.t(),
    credentials: http_credentials(),
    additional_headers: %{String.t() => String.t()} | nil
  }

  @type oauth2_auth :: %{
    client_id: String.t() | nil,
    client_secret: String.t() | nil,
    auth_uri: String.t() | nil,
    state: String.t() | nil,
    redirect_uri: String.t() | nil,
    auth_response_uri: String.t() | nil,
    auth_code: String.t() | nil,
    access_token: String.t() | nil,
    refresh_token: String.t() | nil,
    id_token: String.t() | nil,
    expires_at: integer() | nil,
    expires_in: integer() | nil,
    audience: String.t() | nil,
    token_endpoint_auth_method: String.t() | nil
  }

  @type service_account :: %{
    service_account_credential: map() | nil,
    scopes: [String.t()] | nil,
    use_default_credential: boolean(),
    use_id_token: boolean(),
    audience: String.t() | nil
  }

  defstruct [
    :auth_type, :api_key, :http, :oauth2,
    :service_account, :resource_ref
  ]

  @doc "Returns true if this is a simple credential that needs no exchange/refresh."
  def ready?(%__MODULE__{auth_type: type}) when type in [:api_key, :http], do: true
  def ready?(_), do: false
end
```

```elixir
defmodule ADK.Auth.Config do
  @moduledoc "Bundles auth scheme, raw credential, and exchanged credential."

  @type t :: %__MODULE__{
    auth_scheme: map(),
    raw_auth_credential: ADK.Auth.Credential.t() | nil,
    exchanged_auth_credential: ADK.Auth.Credential.t() | nil,
    credential_key: String.t() | nil
  }

  defstruct [:auth_scheme, :raw_auth_credential,
             :exchanged_auth_credential, :credential_key]

  @doc "Derives a stable credential key from scheme + raw credential."
  def derive_credential_key(%__MODULE__{} = config) do
    data = %{
      scheme: sanitize_scheme(config.auth_scheme),
      credential: sanitize_credential(config.raw_auth_credential)
    }
    hash = :crypto.hash(:sha256, Jason.encode!(data))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "adk_#{config.auth_scheme[:type]}_#{hash}"
  end
end
```

### 2.3 Credential Service Behaviour

```elixir
defmodule ADK.Auth.CredentialService do
  @moduledoc """
  Behaviour for credential persistence backends.

  Credentials are scoped by `{app_name, user_id, credential_key}`.
  """

  @type context :: %{
    app_name: String.t(),
    user_id: String.t(),
    session_id: String.t()
  }

  @callback load_credential(
    auth_config :: ADK.Auth.Config.t(),
    context :: context()
  ) :: {:ok, ADK.Auth.Credential.t()} | :not_found | {:error, term()}

  @callback save_credential(
    auth_config :: ADK.Auth.Config.t(),
    context :: context()
  ) :: :ok | {:error, term()}
end
```

### 2.4 Credential Service Implementations

#### InMemory (ETS-backed)

```elixir
defmodule ADK.Auth.CredentialServices.InMemory do
  @moduledoc """
  ETS-backed in-memory credential service.

  Started as part of the ADK supervision tree.
  Credentials survive process crashes but not node restarts.
  """
  @behaviour ADK.Auth.CredentialService

  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(:adk_credentials, [:set, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl ADK.Auth.CredentialService
  def load_credential(auth_config, context) do
    key = bucket_key(context, auth_config.credential_key)
    case :ets.lookup(table_name(), key) do
      [{^key, credential}] -> {:ok, credential}
      [] -> :not_found
    end
  end

  @impl ADK.Auth.CredentialService
  def save_credential(auth_config, context) do
    key = bucket_key(context, auth_config.credential_key)
    :ets.insert(table_name(), {key, auth_config.exchanged_auth_credential})
    :ok
  end

  defp bucket_key(%{app_name: app, user_id: user}, cred_key) do
    {app, user, cred_key}
  end
end
```

#### Ecto (Database-backed)

```elixir
defmodule ADK.Auth.CredentialServices.Ecto do
  @moduledoc """
  Database-backed credential service using Ecto.

  Credentials are encrypted at rest using the configured encryption module.
  """
  @behaviour ADK.Auth.CredentialService

  @impl ADK.Auth.CredentialService
  def load_credential(auth_config, context) do
    repo = repo()
    case repo.get_by(ADK.Auth.CredentialRecord,
      app_name: context.app_name,
      user_id: context.user_id,
      credential_key: auth_config.credential_key
    ) do
      nil -> :not_found
      record -> {:ok, decrypt_credential(record.encrypted_credential)}
    end
  end

  @impl ADK.Auth.CredentialService
  def save_credential(auth_config, context) do
    attrs = %{
      app_name: context.app_name,
      user_id: context.user_id,
      credential_key: auth_config.credential_key,
      encrypted_credential: encrypt_credential(auth_config.exchanged_auth_credential),
      auth_type: auth_config.exchanged_auth_credential.auth_type
    }

    %ADK.Auth.CredentialRecord{}
    |> ADK.Auth.CredentialRecord.changeset(attrs)
    |> repo().insert(
      on_conflict: {:replace, [:encrypted_credential, :updated_at]},
      conflict_target: [:app_name, :user_id, :credential_key]
    )
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Encryption delegated to configurable module (e.g., Cloak.Ecto)
  defp encrypt_credential(credential), do: ADK.Auth.Encryption.encrypt(credential)
  defp decrypt_credential(data), do: ADK.Auth.Encryption.decrypt(data)
  defp repo, do: Application.get_env(:adk, :repo)
end
```

#### Vault Integration Point

```elixir
defmodule ADK.Auth.CredentialServices.Vault do
  @moduledoc """
  HashiCorp Vault-backed credential service.

  Stub for integration — users implement with their Vault client.
  """
  @behaviour ADK.Auth.CredentialService

  # Users configure vault_client and secret_path via application config
  # Credentials stored at: secret/data/adk/{app_name}/{user_id}/{credential_key}
end
```

### 2.5 Credential Exchanger Behaviour

```elixir
defmodule ADK.Auth.CredentialExchanger do
  @moduledoc "Behaviour for exchanging credentials (e.g., auth_code → access_token)."

  @type exchange_result :: {:exchanged, ADK.Auth.Credential.t()} | :no_exchange

  @callback exchange(
    credential :: ADK.Auth.Credential.t(),
    auth_scheme :: map()
  ) :: {:ok, exchange_result()} | {:error, term()}
end
```

```elixir
defmodule ADK.Auth.Exchangers.OAuth2 do
  @moduledoc "Exchanges OAuth2 auth codes for access tokens."
  @behaviour ADK.Auth.CredentialExchanger

  @impl true
  def exchange(%{auth_type: type, oauth2: oauth2} = credential, auth_scheme)
      when type in [:oauth2, :open_id_connect] do
    cond do
      # Already has access token and no auth code to exchange
      oauth2.access_token && !oauth2.auth_code ->
        {:ok, :no_exchange}

      # Has auth code — exchange it
      oauth2.auth_code ->
        with {:ok, tokens} <- exchange_code(oauth2, auth_scheme) do
          {:ok, {:exchanged, update_tokens(credential, tokens)}}
        end

      # Client credentials flow
      oauth2.client_id && oauth2.client_secret ->
        with {:ok, tokens} <- client_credentials_exchange(oauth2, auth_scheme) do
          {:ok, {:exchanged, update_tokens(credential, tokens)}}
        end

      true ->
        {:ok, :no_exchange}
    end
  end

  def exchange(_credential, _auth_scheme), do: {:ok, :no_exchange}
end
```

### 2.6 Credential Refresher Behaviour

```elixir
defmodule ADK.Auth.CredentialRefresher do
  @moduledoc "Behaviour for refreshing expired credentials."

  @callback refresh_needed?(
    credential :: ADK.Auth.Credential.t(),
    auth_scheme :: map()
  ) :: boolean()

  @callback refresh(
    credential :: ADK.Auth.Credential.t(),
    auth_scheme :: map()
  ) :: {:ok, ADK.Auth.Credential.t()} | {:error, term()}
end
```

```elixir
defmodule ADK.Auth.Refreshers.OAuth2 do
  @behaviour ADK.Auth.CredentialRefresher

  @impl true
  def refresh_needed?(%{oauth2: %{expires_at: expires_at}}, _scheme)
      when is_integer(expires_at) do
    System.system_time(:second) >= expires_at - 300  # 5 min buffer
  end
  def refresh_needed?(_, _), do: false

  @impl true
  def refresh(%{oauth2: %{refresh_token: rt}} = credential, auth_scheme)
      when is_binary(rt) do
    with {:ok, tokens} <- do_refresh(credential.oauth2, auth_scheme) do
      {:ok, update_tokens(credential, tokens)}
    end
  end
end
```

### 2.7 Credential Manager (Stateless Orchestrator)

```elixir
defmodule ADK.Auth.CredentialManager do
  @moduledoc """
  Orchestrates the credential lifecycle: load → exchange → refresh → save.

  Stateless module — all state flows through arguments.
  Mirrors Python's CredentialManager but as pure functions.
  """

  alias ADK.Auth.{Config, Credential, CredentialService}

  @type context :: CredentialService.context()

  @doc """
  Load and prepare a credential for use.

  Returns `{:ok, credential}` if ready, `:needs_auth` if user auth is needed,
  or `{:error, reason}` on failure.
  """
  @spec get_credential(Config.t(), context(), CredentialService.t(), keyword()) ::
    {:ok, Credential.t()} | :needs_auth | {:error, term()}
  def get_credential(auth_config, context, credential_service, opts \\ []) do
    exchangers = Keyword.get(opts, :exchangers, default_exchangers())
    refreshers = Keyword.get(opts, :refreshers, default_refreshers())

    with :ok <- validate(auth_config) do
      # Simple credentials (API key, HTTP) — return immediately
      if Credential.ready?(auth_config.raw_auth_credential) do
        {:ok, auth_config.raw_auth_credential}
      else
        do_get_credential(auth_config, context, credential_service, exchangers, refreshers)
      end
    end
  end

  defp do_get_credential(config, context, service, exchangers, refreshers) do
    # 1. Try persistent store
    credential = case service.load_credential(config, context) do
      {:ok, cred} -> cred
      _ -> nil
    end

    # 2. If not found, check client credentials flow
    {credential, was_loaded} = if credential do
      {credential, true}
    else
      if client_credentials_flow?(config) do
        {config.raw_auth_credential, false}
      else
        {nil, false}
      end
    end

    # 3. No credential available → needs user auth
    if is_nil(credential), do: throw(:needs_auth)

    # 4. Exchange if needed
    {credential, was_exchanged} = maybe_exchange(credential, config.auth_scheme, exchangers)

    # 5. Refresh if needed (only if not just exchanged)
    {credential, was_refreshed} = if was_exchanged do
      {credential, false}
    else
      maybe_refresh(credential, config.auth_scheme, refreshers)
    end

    # 6. Save if modified
    if was_exchanged or was_refreshed or not was_loaded do
      save_config = %{config | exchanged_auth_credential: credential}
      service.save_credential(save_config, context)
    end

    {:ok, credential}
  catch
    :needs_auth -> :needs_auth
  end

  defp default_exchangers do
    %{
      oauth2: ADK.Auth.Exchangers.OAuth2,
      open_id_connect: ADK.Auth.Exchangers.OAuth2,
      service_account: ADK.Auth.Exchangers.ServiceAccount
    }
  end

  defp default_refreshers do
    %{
      oauth2: ADK.Auth.Refreshers.OAuth2,
      open_id_connect: ADK.Auth.Refreshers.OAuth2
    }
  end
end
```

### 2.8 OAuth2 Discovery

```elixir
defmodule ADK.Auth.OAuth2.Discovery do
  @moduledoc """
  RFC 8414 / RFC 9728 OAuth2 metadata discovery.

  Uses Req for HTTP requests (standard Elixir HTTP client).
  """

  @type server_metadata :: %{
    issuer: String.t(),
    authorization_endpoint: String.t(),
    token_endpoint: String.t(),
    scopes_supported: [String.t()] | nil
  }

  @spec discover_auth_server(String.t()) :: {:ok, server_metadata()} | :not_found
  def discover_auth_server(issuer_url) do
    uri = URI.parse(issuer_url)
    base = "#{uri.scheme}://#{uri.authority}"
    path = uri.path || ""

    endpoints = if path != "" and path != "/" do
      [
        "#{base}/.well-known/oauth-authorization-server#{path}",
        "#{base}/.well-known/openid-configuration#{path}",
        "#{base}#{path}/.well-known/openid-configuration"
      ]
    else
      [
        "#{base}/.well-known/oauth-authorization-server",
        "#{base}/.well-known/openid-configuration"
      ]
    end

    Enum.find_value(endpoints, :not_found, fn url ->
      case Req.get(url, receive_timeout: 5_000) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          if body["issuer"] == String.trim_trailing(issuer_url, "/") do
            {:ok, %{
              issuer: body["issuer"],
              authorization_endpoint: body["authorization_endpoint"],
              token_endpoint: body["token_endpoint"],
              scopes_supported: body["scopes_supported"]
            }}
          end
        _ -> nil
      end
    end)
  end
end
```

### 2.9 Phoenix Integration for OAuth Flows

```elixir
defmodule ADK.Auth.Phoenix.OAuthController do
  @moduledoc """
  Phoenix controller for handling OAuth2 callback flows.

  Mount in your router:

      scope "/auth" do
        get "/callback", ADK.Auth.Phoenix.OAuthController, :callback
      end

  The agent requests user auth → client redirects to OAuth provider →
  provider redirects back to /auth/callback → this controller stores
  the credential and signals the waiting agent.
  """
  use Phoenix.Controller

  def callback(conn, %{"code" => code, "state" => state} = params) do
    with {:ok, pending} <- ADK.Auth.PendingAuth.lookup(state),
         {:ok, credential} <- exchange_code(pending, code) do
      # Store via credential service
      ADK.Auth.CredentialManager.store_auth_response(
        pending.auth_config,
        credential,
        pending.context
      )

      # Notify waiting process
      ADK.Auth.PendingAuth.complete(state, credential)

      conn
      |> put_flash(:info, "Authentication successful")
      |> redirect(to: pending.return_path)
    else
      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "Authentication failed", reason: inspect(reason)})
    end
  end
end
```

```elixir
defmodule ADK.Auth.PendingAuth do
  @moduledoc """
  Tracks pending OAuth flows.

  Uses ETS with TTL for state → auth_config mapping.
  Waiting processes subscribe via :pending_auth Registry.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register(state, auth_config, context, return_path) do
    GenServer.call(__MODULE__, {:register, state, auth_config, context, return_path})
  end

  def lookup(state), do: GenServer.call(__MODULE__, {:lookup, state})

  def complete(state, credential) do
    # Broadcast to waiting process via Registry
    Registry.dispatch(ADK.Auth.WaitingRegistry, state, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:auth_complete, state, credential})
    end)
    GenServer.cast(__MODULE__, {:remove, state})
  end
end
```

### 2.10 LiveView Integration

```elixir
defmodule ADK.Auth.Phoenix.AuthLive do
  @moduledoc """
  LiveView component for inline OAuth flows.

  Renders an auth prompt when the agent requests user credentials,
  opens OAuth popup, handles callback via PubSub.
  """
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H\"""
    <div :if={@auth_request} class="adk-auth-prompt">
      <p>This agent needs access to <%= @auth_request.service_name %></p>
      <button phx-click="authorize" phx-target={@myself}>
        Authorize
      </button>
    </div>
    \"""
  end

  def handle_event("authorize", _params, socket) do
    auth_config = socket.assigns.auth_request
    auth_uri = ADK.Auth.AuthHandler.generate_auth_uri(auth_config)
    {:noreply, push_event(socket, "open_oauth_popup", %{url: auth_uri})}
  end

  # PubSub callback when OAuth completes
  def handle_info({:auth_complete, _state, credential}, socket) do
    send(self(), {:resume_agent, credential})
    {:noreply, assign(socket, auth_request: nil)}
  end
end
```

---

## 3. Supervision Tree

```
ADK.Supervisor
├── ADK.Auth.CredentialServices.InMemory  (GenServer + ETS)
├── ADK.Auth.PendingAuth                  (GenServer, TTL cleanup)
├── Registry (ADK.Auth.WaitingRegistry)   (for OAuth flow notification)
└── ... (existing ADK supervisors)
```

---

## 4. Key Design Decisions

### 4.1 Stateless CredentialManager

Python uses a class with `__init__` that sets up registries. Elixir version is a **stateless module** — exchanger/refresher registries are passed as options or use defaults. This is more functional and testable.

### 4.2 ETS over GenServer State for InMemory

Using ETS with `read_concurrency: true` allows concurrent credential reads without serializing through a GenServer. The GenServer owns the ETS table but reads bypass it.

### 4.3 Encryption at Rest for Ecto Backend

Unlike Python's in-memory-only approach, the Ecto backend encrypts credentials. Integration point for `Cloak.Ecto` or custom encryption module via application config.

### 4.4 Registry-Based OAuth Flow Notification

Instead of polling session state (Python's approach), Elixir uses `Registry` for pub/sub notification when OAuth flows complete. The waiting agent process subscribes and gets notified instantly.

### 4.5 No authlib Dependency

Python uses `authlib` for OAuth2 sessions. Elixir uses `Req` + manual OAuth2 logic or `assent` (a well-maintained Elixir OAuth2 library). Keeps dependencies minimal.

---

## 5. Migration Path

### Phase 1: Core Structs + Behaviour
- `ADK.Auth.Credential` struct
- `ADK.Auth.Config` struct  
- `ADK.Auth.CredentialService` behaviour
- `ADK.Auth.CredentialServices.InMemory`

### Phase 2: Exchangers + Refreshers
- `ADK.Auth.CredentialExchanger` behaviour + OAuth2 impl
- `ADK.Auth.CredentialRefresher` behaviour + OAuth2 impl
- `ADK.Auth.CredentialManager` orchestrator

### Phase 3: OAuth Discovery + Phoenix Integration
- `ADK.Auth.OAuth2.Discovery`
- `ADK.Auth.Phoenix.OAuthController`
- `ADK.Auth.PendingAuth`
- LiveView component

### Phase 4: Advanced
- Ecto credential service
- Vault integration point
- Service account exchanger
- Agent-to-agent auth (via A2A protocol's existing auth support)

---

## 6. Agent-to-Agent Auth

The Python ADK handles A2A auth via the A2A protocol layer (agent cards with auth info, not via the credential service). ADK Elixir already has `ADK.A2A.Client` and `ADK.A2A.Server`. The auth system integrates by:

1. **Outbound A2A calls:** `RemoteAgentTool` uses `CredentialManager` to get credentials for the remote agent's required auth scheme
2. **Inbound A2A requests:** `A2A.Server` validates incoming credentials against configured auth (bearer token, OAuth, mTLS)
3. **Service account for server-to-server:** `Exchangers.ServiceAccount` handles GCP service account → access token for authenticated A2A calls

No additional A2A-specific auth modules are needed — the credential system is general enough.
