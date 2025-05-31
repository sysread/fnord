defmodule Store do
  require Logger

  @projects_dir "projects"

  @spec store_home() :: binary
  def store_home() do
    move_projects_into_discrete_folder()

    home = Settings.home()
    File.mkdir_p!(home)

    home
  end

  # -----------------------------------------------------------------------------
  # Projects
  # -----------------------------------------------------------------------------
  @spec get_project(nil | binary) :: Store.Project.t()
  def get_project(nil), do: get_project()

  def get_project(project) when is_binary(project) do
    home = store_home()
    store_path = Path.join([home, @projects_dir, project])
    Store.Project.new(project, store_path)
  end

  def get_project(%Store.Project{} = project) do
    project
  end

  @spec get_project() :: Store.Project.t()
  def get_project() do
    project = Settings.get_selected_project!()
    get_project(project)
  end

  # -----------------------------------------------------------------------------
  # Clean ups for legacy data
  # -----------------------------------------------------------------------------
  defp move_projects_into_discrete_folder() do
    home = Settings.home()
    new_projects_dir = Path.join(home, "projects")

    if !File.exists?(new_projects_dir) do
      Logger.info("Migrating projects to #{new_projects_dir}")

      File.mkdir_p!(new_projects_dir)

      Settings.new()
      |> Settings.list_projects()
      |> Enum.each(fn project_name ->
        old_path = Path.join(store_home(), project_name)
        new_path = Path.join(new_projects_dir, project_name)

        cond do
          File.exists?(old_path) and File.exists?(new_path) ->
            Logger.info("#{project_name} migrated to #{new_path}; cleaning up artifacts")
            File.rm_rf!(new_path)

          File.exists?(old_path) ->
            File.rename(old_path, new_path)
            Logger.info("#{project_name} migrated to #{new_path}")
        end
      end)
    end
  end
end
