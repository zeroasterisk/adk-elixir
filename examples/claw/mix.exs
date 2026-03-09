defmodule Claw.MixProject do
  use Mix.Project

  def project do
    [
      app: :claw,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {Claw.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # ADK Elixir — parent project
      {:adk, path: "../.."},

      # Phoenix stack
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},

      # For A2A server (Plug-based)
      {:plug, "~> 1.14"},

      # Telemetry (required by Phoenix)
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
