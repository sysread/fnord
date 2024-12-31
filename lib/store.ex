defmodule Store do
  require Logger

  @prompts_dir "prompts"
  @non_project_paths MapSet.new([@prompts_dir])

  def store_home() do
    home = Settings.home()
    File.mkdir_p!(home)
    home
  end

  def prompts_dir() do
    Path.join(store_home(), @prompts_dir)
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
  # Prompts
  # -----------------------------------------------------------------------------
  def list_prompts() do
    prompts_dir()
    |> File.ls()
    |> case do
      {:ok, dirs} ->
        dirs
        |> Enum.sort()
        |> Enum.map(&Store.Prompt.new(&1))

      _ ->
        []
    end
  end

  def search_prompts(query, max_results \\ 3) do
    Store.Prompt.install_initial_strategies()

    needle = AI.Util.generate_embeddings!(query)

    list_prompts()
    |> Enum.reduce([], fn prompt, acc ->
      with {:ok, version} = Store.Prompt.version(prompt),
           {:ok, embeddings} <- Store.Prompt.read_embeddings(prompt, version) do
        score = AI.Util.cosine_similarity(needle, embeddings)
        [{score, prompt} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> a >= b end)
    |> Enum.take(max_results)
  end
end
