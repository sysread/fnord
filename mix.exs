defmodule Fnord.MixProject do
  use Mix.Project

  def project do
    [
      app: :fnord,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Fnord]
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
      {:gpt3_tokenizer, "~> 0.1.0"},
      {:jason, "~> 1.4"},
      {:openai_ex, "~> 0.8.3"},
      {:optimus, "~> 0.2"}
    ]
  end
end
