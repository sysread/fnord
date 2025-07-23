defmodule Fnord.MixProject do
  use Mix.Project

  def project do
    [
      app: :fnord,
      version: "0.8.21",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "An AI powered, conversational interface for your project that learns",
      package: package(),
      deps: deps(),
      escript: escript(),
      docs: docs(),
      # TEMP: remove this once https://github.com/jeremyjh/dialyxir/issues/561 is resolved
      dialyzer: [flags: [:no_opaque]]
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
      {:clipboard, "~> 0.2.1"},
      {:dialyxir, "~> 1.4.5", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false},
      {:httpoison, "~> 2.2.1"},
      {:jason, "~> 1.4"},
      {:meck, "~> 1.0", only: [:test], runtime: false},
      {:mox, "~> 1.2", only: [:test], runtime: false},
      {:number, "~> 1.0.5"},
      {:optimus, "~> 0.2"},
      {:owl, "~> 0.12"},
      {:uniq, "~> 0.1"},
      {:yaml_elixir, "~> 2.11"}
    ]
  end
end
