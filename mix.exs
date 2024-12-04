defmodule Fnord.MixProject do
  use Mix.Project

  def project do
    [
      app: :fnord,
      version: "0.4.38",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: "Index, search, and investigate your code base with OpenAI's embeddings API",
      package: package(),
      deps: deps(),
      escript: escript(),
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: "https://github.com/sysread/fnord",
      homepage_url: "https://hex.pm/packages/fnord",
      format: :html
    ]
  end

  defp package do
    [
      maintainers: ["Jeff Ober"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/sysread/fnord"}
    ]
  end

  defp escript do
    [
      main_module: Fnord
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:briefly, "~> 0.5.1"},
      {:dialyxir, "~> 1.4.4", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false},
      {:jason, "~> 1.4"},
      {:number, "~> 1.0.5"},
      {:optimus, "~> 0.2"},
      {:owl, "~> 0.12"},
      {:httpoison, "~> 2.2.1"}
    ]
  end
end
