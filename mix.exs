defmodule ADK.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/zeroasterisk/adk-elixir"

  def project do
    [
      app: :adk,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "ADK Elixir",
      source_url: @source_url,
      homepage_url: "https://zeroasterisk.github.io/adk-elixir",
      docs: docs()
    ]
  end

  def application do
    [
      mod: {ADK.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.14", optional: true}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/concepts.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        "Core": [ADK, ADK.Agent, ADK.Tool, ADK.Event, ADK.Context],
        "Agents": [ADK.Agent.LlmAgent, ADK.Agent.SequentialAgent],
        "Tools": [ADK.Tool.FunctionTool, ADK.Tool.Declarative],
        "State & Sessions": [ADK.Session, ADK.Session.Store, ADK.Session.Store.InMemory, ADK.Session.Store.JsonFile, ADK.State.Delta, ADK.EventActions],
        "LLM": [ADK.LLM, ADK.LLM.Mock, ADK.LLM.Gemini, ADK.LLM.OpenAI],
        "Runner": [ADK.Runner]
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ]
    ]
  end
end
