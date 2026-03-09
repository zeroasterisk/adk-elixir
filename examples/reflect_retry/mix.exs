defmodule ReflectRetry.MixProject do
  use Mix.Project

  def project do
    [
      app: :reflect_retry,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:adk, path: "../.."},
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"}
    ]
  end
end
