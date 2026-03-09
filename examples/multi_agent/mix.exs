defmodule MultiAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :multi_agent,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MultiAgent.Application, []}
    ]
  end

  defp deps do
    [
      {:adk, path: "../.."},
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"}
    ]
  end
end
