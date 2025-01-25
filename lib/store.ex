defmodule Store do
  require Logger

  @strategies_dir "strategies"
  @non_project_paths MapSet.new([@strategies_dir])

  def store_home() do
    home = Settings.home()
    File.mkdir_p!(home)
    home
  end

  # -----------------------------------------------------------------------------
  # Projects
  # -----------------------------------------------------------------------------
  def get_project(nil), do: get_project()

  def get_project(project_name) do
    home = store_home()
    store_path = Path.join(home, project_name)
    Store.Project.new(project_name, store_path)
  end

  def get_project() do
    project = Settings.get_selected_project!()
    get_project(project)
  end

  def list_projects() do
    home = Settings.home()

    home
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.basename/1)
    |> Enum.reject(&MapSet.member?(@non_project_paths, &1))
    |> Enum.map(&Store.Project.new(&1, home))
  end

  # -----------------------------------------------------------------------------
  # Strategies
  # -----------------------------------------------------------------------------
  def strategies_dir() do
    Path.join(store_home(), @strategies_dir)
  end

  def list_strategies() do
    strategies_dir()
    |> File.ls()
    |> case do
      {:ok, dirs} ->
        dirs
        |> Enum.sort()
        |> Enum.map(&Store.Strategy.new(&1))

      _ ->
        []
    end
  end

  def search_strategies(query, max_results \\ 3) do
    Store.Strategy.install_initial_strategies()

    {:ok, needle} =
      Indexer.impl().new()
      |> Indexer.impl().get_embeddings(query)

    strategies = list_strategies()
    workers = Enum.count(strategies)

    strategies
    |> Util.async_stream(
      fn strategy ->
        with {:ok, embeddings} <- Store.Strategy.read_embeddings(strategy) do
          {:ok, {strategy, embeddings}}
        end
      end,
      max_concurrency: workers
    )
    |> Util.async_stream(
      fn
        {:ok, {:ok, {strategy, embeddings}}} ->
          score = AI.Util.cosine_similarity(needle, embeddings)
          {score, strategy}

        _ ->
          nil
      end,
      max_concurrency: workers
    )
    # Collect the results
    |> Enum.reduce([], fn
      {:ok, {score, strategy}}, acc -> [{score, strategy} | acc]
      _, acc -> acc
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> a >= b end)
    |> Enum.take(max_results)
  end
end
