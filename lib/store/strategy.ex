defmodule Store.Strategy do
  @moduledoc """
  This module provides access to canned research strategies. Strategies are
  stored in `data/strategies.yaml` in the repo, but are read into this module
  at compile time, so the file itself is not a part of the release binary.
  """

  @strategies_file "data/strategies.yaml"
  @external_resource @strategies_file
  @strategies YamlElixir.read_from_file!(@strategies_file)

  @doc """
  Returns a map of research strategies where each key is the `title`.
  """
  def list() do
    @strategies
    |> Enum.map(fn %{"title" => title} = strategy -> {title, strategy} end)
    |> Enum.into(%{})
  end

  @doc """
  Returns a single research strategy by its `title`.
  """
  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get(title) do
    @strategies
    |> Enum.find(fn strategy -> strategy["title"] == title end)
    |> then(fn
      nil -> {:error, :not_found}
      %{"steps" => steps} -> {:ok, steps}
    end)
  end
end
