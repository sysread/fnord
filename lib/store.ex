defmodule Store do
  require Logger

  @spec get_project() :: binary
  def store_home() do
    clean_old_strategies_dirs()

    home = Settings.home()
    File.mkdir_p!(home)

    home
  end

  # -----------------------------------------------------------------------------
  # Projects
  # -----------------------------------------------------------------------------
  @spec get_project(nil | binary) :: Store.Project.t()
  def get_project(nil), do: get_project()

  def get_project(project_name) do
    home = store_home()
    store_path = Path.join(home, project_name)
    Store.Project.new(project_name, store_path)
  end

  @spec get_project() :: Store.Project.t()
  def get_project() do
    project = Settings.get_selected_project!()
    get_project(project)
  end

  @spec list_projects :: [Store.Project.t()]
  def list_projects() do
    home = Settings.home()

    home
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.basename/1)
    |> Enum.map(&Store.Project.new(&1, home))
  end

  # -----------------------------------------------------------------------------
  # Clean ups for legacy data
  # -----------------------------------------------------------------------------

  # Strategies used to be persisted in the Store under either
  # `$HOME/.fnord/strategies` or `$HOME/.fnord/prompts`. This function removes
  # those deprecated directories.
  defp clean_old_strategies_dirs() do
    prompts_dir = Settings.home() |> Path.join("prompts")

    if File.dir?(prompts_dir) do
      UI.debug("Removing deprecated store dir: #{prompts_dir}")
      File.rm_rf!(prompts_dir)
    end

    strategies_dir = Settings.home() |> Path.join("strategies")

    if File.dir?(strategies_dir) do
      UI.debug("Removing deprecated store dir: #{strategies_dir}")
      File.rm_rf!(strategies_dir)
    end
  end
end
