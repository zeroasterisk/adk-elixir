defmodule ADK.MixProject do
  use Mix.Project

  @version "0.0.1-alpha.2"
  @source_url "https://github.com/zeroasterisk/adk-elixir"
  @description "Agent Development Kit for Elixir — OTP-native AI agent framework inspired by Google ADK"

  def project do
    [
      app: :adk,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),

      # Docs
      name: "ADK",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      mod: {ADK.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: "adk",
      description: @description,
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Google ADK (Python)" => "https://github.com/google/adk-python"
      },
      files: ~w(
        lib priv mix.exs
        README.md LICENSE CHANGELOG.md
      )
    ]
  end

  defp deps do
    [
      {:mox, "~> 1.0", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      # A2A protocol support — optional, install {:a2a, "~> 0.2"} to enable
      # See: https://hex.pm/packages/a2a
      {:a2a, "~> 0.2", optional: true},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.14", optional: true},
      {:bandit, "~> 1.5", optional: true},
      {:ecto, "~> 3.10", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:telemetry, "~> 1.0"},
      {:opentelemetry_api, "~> 1.0", optional: true},
      {:opentelemetry, "~> 1.3", only: :test},
      {:oban, "~> 2.18", optional: true},
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_html, "~> 4.0", optional: true},
      {:yaml_elixir, "~> 2.11"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/intentional-differences.md",
        "guides/getting-started.md",
        "guides/concepts.md",
        "guides/mix-adk-new.md",
        "guides/evaluations.md",
        "guides/phoenix-integration.md",
        "guides/supervision.md",
        "guides/oban-integration.md",
        "guides/dev-server.md",
        "guides/adk-web-compatibility.md",
        "guides/deployment.md",
        "guides/benchmarks.md",
        "guides/agent-patterns.md",
        "guides/context-compilation.md",
        "guides/context-engineering.md",
        "guides/human-in-the-loop.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        "Core": [ADK, ADK.Agent, ADK.Tool, ADK.Event, ADK.Context, ADK.ToolContext],
        "Agents": [
          ADK.Agent.LlmAgent,
          ADK.Agent.SequentialAgent,
          ADK.Agent.ParallelAgent,
          ADK.Agent.LoopAgent,
          ADK.Agent.Custom
        ],
        "Tools": [
          ADK.Tool.FunctionTool,
          ADK.Tool.Declarative,
          ADK.Tool.ModuleTool,
          ADK.Tool.TransferTool,
          ADK.Tool.TransferToAgent,
          ADK.Tool.SearchMemoryTool,
          ADK.Tool.GoogleSearch,
          ADK.Tool.BuiltInCodeExecution
        ],
        "LLM Backends": [
          ADK.LLM,
          ADK.LLM.Mock,
          ADK.LLM.Gemini,
          ADK.LLM.OpenAI,
          ADK.LLM.Anthropic,
          ADK.LLM.Retry,
          ADK.LLM.CircuitBreaker
        ],
        "Sessions & State": [
          ADK.Session,
          ADK.Session.Store,
          ADK.Session.Store.InMemory,
          ADK.Session.Store.JsonFile,
          ADK.Session.Store.Ecto,
          ADK.State.Delta,
          ADK.EventActions,
          ADK.RunConfig
        ],
        "Memory": [
          ADK.Memory.Entry,
          ADK.Memory.Store,
          ADK.Memory.InMemory
        ],
        "Context & Compression": [
          ADK.Context.Compressor,
          ADK.Context.Compressor.Summarize,
          ADK.Context.Compressor.Truncate,
          ADK.Context.Compressor.SlidingWindow
        ],
        "Artifacts": [
          ADK.Artifact.Store,
          ADK.Artifact.InMemory,
          ADK.Artifact.GCS
        ],
        "Auth": [
          ADK.Auth.Config,
          ADK.Auth.Credential,
          ADK.Auth.CredentialStore,
          ADK.Auth.InMemoryStore
        ],
        "Runner": [ADK.Runner, ADK.Runner.Async],
        "A2A Protocol": [
          ADK.A2A.Server,
          ADK.A2A.Client,
          ADK.A2A.AgentCard,
          ADK.A2A.Message,
          ADK.A2A.RemoteAgentTool
        ],
        "Phoenix Integration": [
          ADK.Phoenix.Controller,
          ADK.Phoenix.Channel,
          ADK.Phoenix.LiveHandler,
          ADK.Phoenix.ChatLive,
          ADK.Phoenix.WebRouter
        ],
        "Plugins": [
          ADK.Plugin,
          ADK.Plugin.Registry,
          ADK.Plugin.ReflectRetry
        ],
        "MCP": [
          ADK.MCP.Client,
          ADK.MCP.ToolAdapter
        ],
        "Oban": [ADK.Oban.AgentWorker],
        "Policies": [ADK.Policy, ADK.Policy.DefaultPolicy],
        "Eval": [
          ADK.Eval,
          ADK.Eval.Case,
          ADK.Eval.Scorer,
          ADK.Eval.Result,
          ADK.Eval.Report,
          ADK.Eval.Scorer.ExactMatch,
          ADK.Eval.Scorer.Contains,
          ADK.Eval.Scorer.ToolUsed,
          ADK.Eval.Scorer.ResponseLength
        ],
        "Telemetry": [ADK.Telemetry, ADK.Telemetry.SpanStore, ADK.Telemetry.DebugHandler],
        "Mix Tasks": [Mix.Tasks.Adk.New, Mix.Tasks.Adk.Gen.Migration, Mix.Tasks.Adk.Server],
        "Internal": [ADK.Application, ADK.Callback, ADK.InstructionCompiler]
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ]
    ]
  end
end
