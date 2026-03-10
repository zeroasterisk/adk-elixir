defmodule RagAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :rag_agent,
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
      {:jason, "~> 1.4"},
      {:plug, "~> 1.14"}
    ]
  end
end
