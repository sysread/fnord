defmodule Store do
  @projects_dir "projects"

  @spec store_home() :: binary
  def store_home() do
    move_projects_into_discrete_folder()

    home = Settings.fnord_home()
    File.mkdir_p!(home)

    home
  end

  # -----------------------------------------------------------------------------
  # Projects
  # -----------------------------------------------------------------------------
  @doc """
  Returns an ok tuple with a `Store.Project.t`, identified either by name or by
  simply passing through a `Store.Project.t` instance. If passed nil, it
  attempts to use the currently selected project (specified with `--project` or
  via cwd).
  """
  @spec get_project(nil | binary | Store.Project.t()) ::
          {:ok, Store.Project.t()}
          | {:error, :project_not_found}
          | {:error, :project_not_set}
  def get_project(nil), do: get_project()
  def get_project(%Store.Project{} = project), do: {:ok, project}

  def get_project(project) when is_binary(project) do
    home = store_home()
    store_path = Path.join([home, @projects_dir, project])
    {:ok, Store.Project.new(project, store_path)}
  end

  @doc """
  Retrieves the currently selected project (specified with `--project` or via
  cwd) as a `Store.Project.t`. If unset, returns `{:error, :project_not_set}`.
  """
  @spec get_project() ::
          {:ok, Store.Project.t()}
          | {:error, :project_not_found}
          | {:error, :project_not_set}
  def get_project() do
    with {:ok, name} <- Settings.get_selected_project() do
      get_project(name)
    end
  end

  # -----------------------------------------------------------------------------
  # Clean ups for legacy data
  # -----------------------------------------------------------------------------
  defp move_projects_into_discrete_folder() do
    home = Settings.fnord_home()
    new_projects_dir = Path.join(home, "projects")

    if !File.exists?(new_projects_dir) do
      UI.info("Migrating projects to #{new_projects_dir}")

      File.mkdir_p!(new_projects_dir)

      Settings.new()
      |> Settings.list_projects()
      |> Enum.each(fn project_name ->
        old_path = Path.join(store_home(), project_name)
        new_path = Path.join(new_projects_dir, project_name)

        cond do
          File.exists?(old_path) and File.exists?(new_path) ->
            UI.info("#{project_name} migrated to #{new_path}; cleaning up artifacts")
            File.rm_rf!(new_path)

          File.exists?(old_path) ->
            File.rename(old_path, new_path)
            UI.info("#{project_name} migrated to #{new_path}")
        end
      end)
    end
  end
end
