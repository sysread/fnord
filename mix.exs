defmodule Fnord.MixProject do
  use Mix.Project

  def project do
    [
      app: :fnord,
      version: "0.2.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: "Index and search your code base with OpenAI's embeddings API",
      package: package(),
      deps: deps(),
      escript: escript(),
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
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
    [main_module: Fnord]
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
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:gpt3_tokenizer, "~> 0.1.0"},
      {:jason, "~> 1.4"},
      {:openai_ex, "~> 0.8.3"},
      {:optimus, "~> 0.2"}
    ]
  end
end
