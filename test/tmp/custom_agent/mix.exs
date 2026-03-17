defmodule CustomAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :custom_agent,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CustomAgent.Application, []}
    ]
  end

  defp deps do
    [
      {:adk, "~> 0.1.0"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.14"}
    ]
  end
end
