defmodule ContextCompilation.MixProject do
  use Mix.Project

  def project do
    [
      app: :context_compilation,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:adk, path: "../.."},
      {:plug, "~> 1.14"},
      {:bandit, "~> 1.5"}
    ]
  end
end
