defmodule Fnord.MixProject do
  use Mix.Project

  def project do
    [
      app: :fnord,
      version: "0.9.40",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: "AI code archaeology",
      package: package(),
      deps: deps(),
      escript: escript(),
      cli: cli(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      test_ignore_filters: [
        ~r/^test\/support\/.*\.ex/
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  defp docs do
    # Glob the two user-facing doc lanes so adding a new guide or use-case
    # doc auto-publishes it to hexdocs. The self-help tool
    # (`AI.Tools.SelfHelp.Docs`) globs the same two directories at compile
    # time for its URL list, so both stay in sync without hand-editing two
    # lists. The root README.md at the top is separate from each lane's
    # README.md to avoid a `readme.html` filename collision in the published
    # output; each lane README is a hand-curated index that lives only in the
    # repo and on GitHub.
    user_guides =
      "docs/user/*.md"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == "docs/user/README.md"))
      |> Enum.sort()

    use_cases =
      "docs/use-cases/*.md"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == "docs/use-cases/README.md"))
      |> Enum.sort()

    [
      main: "readme",
      extras: ["README.md" | user_guides ++ use_cases],
      groups_for_extras: [Guides: user_guides, "Use cases": use_cases],
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
      main_module: Fnord,
      strip_beams: Mix.env() == :prod
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
      {:excoveralls, "~> 0.18.5", only: [:test], runtime: false},
      # finch >= 0.22 rejects hermes_mcp 0.14.1's :transport_opts via
      # Keyword.validate! in Finch.Request.build/5. Hermes upstream has been
      # dormant since Aug 2025, so cap finch below 0.22 until a fix ships.
      {:finch, ">= 0.19.0 and < 0.22.0"},
      {:hermes_mcp, "~> 0.14"},
      {:httpoison, "~> 2.2.1"},
      {:jason, "~> 1.4"},
      {:mox, "~> 1.2", only: [:test], runtime: false},
      {:optimus, "~> 0.2"},
      {:owl, "~> 0.12"},
      {:stemmer, "~> 1.2"},
      {:toml, "~> 0.7"},
      {:uniq, "~> 0.1"},
      {:yaml_elixir, "~> 2.9"},
      # OAuth2 browser-based flow (loopback server)
      {:plug_cowboy, "~> 2.7"}
    ]
  end
end
