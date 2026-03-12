# Deploying ADK Elixir Applications

This guide covers deploying ADK Elixir applications — specifically Phoenix-based agents
like the [Claw example](../examples/claw/) — to **Cloud Run**, **Fly.io**, and **Gigalixir**.

## Table of Contents

- [Dockerfile](#dockerfile)
- [Cloud Run](#cloud-run)
- [Fly.io](#flyio)
- [Gigalixir](#gigalixir)
- [Environment Variables Reference](#environment-variables-reference)
- [Production Checklist](#production-checklist)

---

## Dockerfile

A multi-stage Dockerfile keeps your production image small (~30 MB) while handling
the full Elixir/OTP release build. This Dockerfile works for **any** provider that
accepts container images (Cloud Run, Fly.io, etc.).

```dockerfile
# ---- Stage 1: Builder ----
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.2
ARG DEBIAN_VERSION=bookworm-20240904-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod

# Install dependencies first (better layer caching)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy config files needed at compile time
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy application code
COPY lib lib
COPY priv priv

# If you have Phoenix assets (esbuild/tailwind), build them:
# COPY assets assets
# RUN mix assets.deploy

# Compile the application
RUN mix compile --warnings-as-errors

# Copy runtime config (needed in release)
COPY config/runtime.exs config/

# Build the OTP release
RUN mix release

# ---- Stage 2: Runner ----
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Create non-root user
RUN useradd --create-home app
USER app

# Copy the release from the builder
COPY --from=builder --chown=app:app /app/_build/prod/rel/claw ./

ENV PORT=8080
ENV PHX_HOST=localhost

# Health check endpoint (see below)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:${PORT}/health || exit 1

EXPOSE ${PORT}

CMD ["bin/claw", "start"]
```

### Health Check Endpoint

Add a simple health check plug to your router or endpoint:

```elixir
# lib/claw/router.ex (or a dedicated plug)
get "/health" do
  send_resp(conn, 200, "ok")
end
```

Or as a minimal Plug in your endpoint:

```elixir
# In lib/claw/endpoint.ex, before the router:
plug :health_check

defp health_check(%Plug.Conn{request_path: "/health"} = conn, _opts) do
  conn |> Plug.Conn.send_resp(200, "ok") |> Plug.Conn.halt()
end

defp health_check(conn, _opts), do: conn
```

### Adapting for Your App

The Dockerfile above targets the Claw example. For your own app:

1. Replace `claw` with your app name in the `CMD` line
2. Uncomment the assets lines if you use esbuild/tailwind
3. If your app is an umbrella or depends on ADK as a path dep, adjust `COPY` lines:

```dockerfile
# For a standalone app using ADK from hex:
COPY mix.exs mix.lock ./

# For the Claw example (ADK as path dependency):
COPY examples/claw/mix.exs examples/claw/mix.lock ./
COPY lib lib  # ADK source
COPY mix.exs mix.lock ./  # root ADK project
```

---

## Cloud Run

Cloud Run is ideal for ADK agents — it scales to zero, handles HTTPS automatically,
and integrates natively with Vertex AI via Workload Identity (no API keys needed).

### Prerequisites

```bash
# Install gcloud CLI: https://cloud.google.com/sdk/docs/install
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### Step 1: Create Artifact Registry Repository

```bash
gcloud artifacts repositories create adk-agents \
  --repository-format=docker \
  --location=us-central1 \
  --description="ADK Elixir agent images"
```

### Step 2: Build and Push the Image

```bash
# Configure Docker for Artifact Registry
gcloud auth configure-docker us-central1-docker.pkg.dev

# Build the image
docker build -t us-central1-docker.pkg.dev/YOUR_PROJECT/adk-agents/claw:latest .

# Push to Artifact Registry
docker push us-central1-docker.pkg.dev/YOUR_PROJECT/adk-agents/claw:latest
```

Or use Cloud Build (no local Docker needed):

```bash
gcloud builds submit --tag us-central1-docker.pkg.dev/YOUR_PROJECT/adk-agents/claw:latest .
```

### Step 3: Deploy to Cloud Run

```bash
# Generate a secret key base
SECRET=$(mix phx.gen.secret)

gcloud run deploy claw-agent \
  --image us-central1-docker.pkg.dev/YOUR_PROJECT/adk-agents/claw:latest \
  --region us-central1 \
  --platform managed \
  --allow-unauthenticated \
  --port 8080 \
  --set-env-vars "PHX_HOST=claw-agent-HASH-uc.a.run.app,SECRET_KEY_BASE=${SECRET},MIX_ENV=prod,GOOGLE_API_KEY=your-api-key" \
  --min-instances 0 \
  --max-instances 10 \
  --memory 512Mi \
  --cpu 1
```

> **Tip:** After deployment, Cloud Run gives you the actual hostname. Update `PHX_HOST`
> with `gcloud run services update claw-agent --set-env-vars PHX_HOST=your-actual-host`.

### ADK-Specific Configuration

Set model and API key via environment variables:

```bash
gcloud run services update claw-agent \
  --set-env-vars "GOOGLE_API_KEY=your-gemini-api-key,ADK_MODEL=gemini-flash-latest"
```

Then read them in `config/runtime.exs`:

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :adk, :default_model,
    System.get_env("ADK_MODEL", "gemini-flash-latest")

  # Gemini API key (used by ADK.LLM.Gemini)
  config :adk, :google_api_key,
    System.get_env("GOOGLE_API_KEY")
end
```

### Scaling Considerations

| Setting | Cost-Optimized | Latency-Optimized |
|---------|---------------|-------------------|
| `--min-instances` | `0` | `1` |
| `--max-instances` | `5` | `20` |
| `--cpu-throttling` | (default, throttled) | `--no-cpu-throttling` |
| `--memory` | `256Mi` | `512Mi` |

For agents with long-running conversations, consider `--session-affinity` and
`--request-timeout 300` (5 minutes).

### Using Vertex AI Instead of API Keys (Workload Identity)

If you're using Vertex AI (rather than the Gemini Developer API), you can skip API keys
entirely and use the Cloud Run service account:

```bash
# Grant the Cloud Run service account access to Vertex AI
gcloud projects add-iam-policy-binding YOUR_PROJECT \
  --member="serviceAccount:YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role="roles/aiplatform.user"
```

Then configure ADK to use Vertex AI:

```elixir
# config/runtime.exs
config :adk, :llm_backend, :vertex_ai
config :adk, :vertex_project, System.get_env("GOOGLE_CLOUD_PROJECT")
config :adk, :vertex_location, System.get_env("GOOGLE_CLOUD_REGION", "us-central1")
```

No API key needed — Cloud Run's default service account authenticates automatically.

---

## Fly.io

Fly.io is great for Elixir — it supports clustering, persistent volumes, and deploys
from a Dockerfile with minimal configuration.

### Prerequisites

```bash
# Install flyctl: https://fly.io/docs/flyctl/install/
fly auth login
```

### Step 1: Launch

From your project directory:

```bash
fly launch --no-deploy
```

This creates a `fly.toml`. Edit it or replace with the example below.

### Step 2: Configure `fly.toml`

```toml
app = "claw-agent"
primary_region = "iad"

[build]

[env]
  MIX_ENV = "prod"
  PHX_HOST = "claw-agent.fly.dev"
  PORT = "8080"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0

  [http_service.concurrency]
    type = "connections"
    hard_limit = 100
    soft_limit = 80

  [[http_service.checks]]
    grace_period = "10s"
    interval = "30s"
    method = "GET"
    timeout = "5s"
    path = "/health"

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
```

### Step 3: Set Secrets

```bash
# Generate and set secrets
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
fly secrets set GOOGLE_API_KEY=your-gemini-api-key
```

### Step 4: Deploy

```bash
fly deploy
```

### Volume Mounts (Optional)

If your agent uses file-based storage (SQLite sessions, artifact files):

```bash
# Create a volume
fly volumes create adk_data --region iad --size 1
```

Add to `fly.toml`:

```toml
[mounts]
  source = "adk_data"
  destination = "/app/data"
```

Then configure your app to use `/app/data`:

```elixir
# config/runtime.exs
config :adk, :json_store_path, "/app/data/sessions"
```

### Fly.io Clustering (Optional)

Elixir on Fly supports automatic clustering via `dns_cluster`:

```elixir
# In your application supervisor children:
{DNSCluster, query: System.get_env("DNS_CLUSTER_QUERY")}
```

```toml
# fly.toml
[env]
  DNS_CLUSTER_QUERY = "claw-agent.internal"
```

---

## Gigalixir

Gigalixir is purpose-built for Elixir — no Docker needed. It uses buildpacks
and handles releases automatically.

### Prerequisites

```bash
# Install the CLI
pip install gigalixir

# Log in
gigalixir login
```

### Step 1: Create an App

```bash
gigalixir create --name claw-agent
```

### Step 2: Configure Buildpacks

Create these files in your project root:

```bash
# .buildpacks
echo "https://github.com/HashNuke/heroku-buildpack-elixir" > .buildpacks
echo "https://github.com/gjaldon/heroku-buildpack-phoenix-static" >> .buildpacks
```

```bash
# elixir_buildpack.config
echo "elixir_version=1.17.3" > elixir_buildpack.config
echo "erlang_version=27.2" >> elixir_buildpack.config
```

### Step 3: Set Environment Variables

```bash
gigalixir config:set SECRET_KEY_BASE=$(mix phx.gen.secret)
gigalixir config:set GOOGLE_API_KEY=your-gemini-api-key
gigalixir config:set PHX_HOST=claw-agent.gigalixirapp.com
gigalixir config:set ADK_MODEL=gemini-flash-latest
```

### Step 4: Deploy

```bash
# Add Gigalixir as a git remote
gigalixir git:remote claw-agent

# Deploy
git push gigalixir main
```

### Step 5: Check Status

```bash
gigalixir ps
gigalixir logs
```

### Free Tier Limitations

| Limit | Value |
|-------|-------|
| Apps | 1 |
| Size | 0.3 GB memory |
| Database | 10k rows (PostgreSQL) |
| Custom domains | ❌ |
| Clustering | ❌ |
| Hot upgrades | ❌ |

> **Note:** The free tier is fine for demos. For production agents, use a paid tier
> or consider Cloud Run / Fly.io.

### Database (If Needed)

```bash
# Create a free-tier PostgreSQL database
gigalixir pg:create --free

# Run migrations
gigalixir run mix ecto.migrate
```

---

## Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MIX_ENV` | Yes | `dev` | Set to `prod` for production |
| `PORT` | Yes | `4000` | HTTP listen port (Cloud Run uses `8080`) |
| `PHX_HOST` | Yes | `localhost` | Public hostname for URL generation |
| `SECRET_KEY_BASE` | Yes | — | Phoenix secret; generate with `mix phx.gen.secret` |
| `GOOGLE_API_KEY` | Conditional | — | Gemini Developer API key |
| `GEMINI_API_KEY` | Conditional | — | Alias for `GOOGLE_API_KEY` (some configs) |
| `ADK_MODEL` | No | `gemini-flash-latest` | Default LLM model name |
| `GOOGLE_CLOUD_PROJECT` | Conditional | — | GCP project ID (for Vertex AI) |
| `GOOGLE_CLOUD_REGION` | No | `us-central1` | GCP region (for Vertex AI) |
| `POOL_SIZE` | No | `10` | Database connection pool size |
| `DATABASE_URL` | Conditional | — | PostgreSQL URL (if using Ecto) |
| `DNS_CLUSTER_QUERY` | No | — | DNS name for Erlang clustering (Fly.io) |
| `CLAW_TEMP` | No | `0.7` | LLM temperature (Claw example) |
| `CLAW_MAX_TOKENS` | No | `8192` | Max output tokens (Claw example) |
| `PHX_SERVER` | No | `true` | Start the Phoenix server (set in release config) |

### Reading Environment Variables

All env vars should be read in `config/runtime.exs`, which runs at boot time
(not compile time):

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE not set. Generate one with: mix phx.gen.secret"

  host = System.get_env("PHX_HOST", "localhost")
  port = String.to_integer(System.get_env("PORT", "4000"))

  config :my_app, MyApp.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true

  # ADK / Gemini configuration
  if api_key = System.get_env("GOOGLE_API_KEY") do
    config :adk, :google_api_key, api_key
  end

  config :adk, :default_model,
    System.get_env("ADK_MODEL", "gemini-flash-latest")
end
```

---

## Production Checklist

### Release Configuration

Ensure your `mix.exs` has a release defined:

```elixir
# mix.exs
def project do
  [
    app: :claw,
    # ...
    releases: [
      claw: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  ]
end
```

### Verify `config/runtime.exs`

- [ ] `SECRET_KEY_BASE` is read from env (not hardcoded)
- [ ] `PHX_HOST` is read from env
- [ ] `PORT` is read from env
- [ ] `GOOGLE_API_KEY` is read from env
- [ ] `server: true` is set in prod (or `PHX_SERVER=true`)
- [ ] No compile-time secrets in `config.exs` or `prod.exs`

### Build Verification

```bash
# Compile with warnings as errors
MIX_ENV=prod mix compile --warnings-as-errors

# Build the release locally to verify
MIX_ENV=prod mix release

# Test the release starts
SECRET_KEY_BASE=$(mix phx.gen.secret) \
  PHX_HOST=localhost \
  PORT=4000 \
  _build/prod/rel/claw/bin/claw start
```

### Database Migrations (If Using Ecto)

For releases, migrations don't run automatically. Add a release module:

```elixir
# lib/claw/release.ex
defmodule Claw.Release do
  @app :claw

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.ensure_all_started(@app)
end
```

Run migrations on deployment:

```bash
# Cloud Run / Fly.io (after deploy)
bin/claw eval "Claw.Release.migrate()"

# Gigalixir
gigalixir run mix ecto.migrate
```

### Secrets Management

| Provider | How |
|----------|-----|
| Cloud Run | `gcloud run services update --set-env-vars` or Secret Manager |
| Fly.io | `fly secrets set KEY=value` (encrypted at rest) |
| Gigalixir | `gigalixir config:set KEY=value` |

**Best practice:** Never commit secrets. Use provider-specific secret management.
For GCP, consider [Secret Manager](https://cloud.google.com/secret-manager) for
rotating API keys.

### Logging

Elixir's Logger works out of the box. For structured logging in Cloud Run:

```elixir
# config/prod.exs
config :logger, :console,
  format: {Jason, :encode!},
  metadata: [:request_id, :module]
```

This outputs JSON logs that Cloud Logging parses automatically.

### Monitoring

- **Cloud Run:** Built-in metrics in Cloud Console; add Cloud Trace for latency
- **Fly.io:** `fly logs`, `fly status`, Grafana dashboard
- **Gigalixir:** `gigalixir logs`, `gigalixir ps`

For all providers, consider adding `:telemetry` metrics:

```elixir
# ADK emits telemetry events you can hook into:
# [:adk, :runner, :start]
# [:adk, :runner, :stop]
# [:adk, :llm, :request, :start]
# [:adk, :llm, :request, :stop]
```

---

## Quick Reference: Provider Comparison

| Feature | Cloud Run | Fly.io | Gigalixir |
|---------|-----------|--------|-----------|
| Container-based | ✅ | ✅ | ❌ (buildpacks) |
| Scale to zero | ✅ | ✅ | ❌ |
| Free tier | ✅ (generous) | ✅ (limited) | ✅ (1 app) |
| Erlang clustering | ❌ | ✅ | ✅ (paid) |
| Persistent volumes | ❌ | ✅ | ❌ |
| Custom domains | ✅ | ✅ | ✅ (paid) |
| Vertex AI integration | ✅ (native IAM) | Manual | Manual |
| Hot upgrades | ❌ | ❌ | ✅ |
| Deploy method | `gcloud run deploy` | `fly deploy` | `git push` |
| Best for | GCP-native, Vertex AI | Full Elixir experience | Simplicity |
