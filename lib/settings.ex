defmodule Settings do
  defstruct [:path, :data]

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new() do
    cleanup_default_project_dir()
    path = settings_file()
    maybe_migrate_settings(path)

    %Settings{path: path}
    |> slurp()
  end

  # ----------------------------------------------------------------------------
  # Cleans up the "default" project directory within the store on startup.
  #
  # This function exists to remove any lingering "default" project data which
  # might cause inconsistencies or conflicts. It is safe to call repeatedly
  # and will not raise errors if the directory does not exist. Moreover, no
  # code depends on this directory being present, so removing it has no adverse
  # side effects.
  # ----------------------------------------------------------------------------
  defp cleanup_default_project_dir do
    path = Path.join(home(), "default")

    if File.exists?(path) do
      File.rm_rf!(path)
    end
  end

  defp get_running_version do
    # Allow version override for testing
    case Application.get_env(:fnord, :test_version_override) do
      nil -> Application.spec(:fnord, :vsn) |> to_string()
      version -> version
    end
  end

  defp maybe_migrate_settings(path) do
    ver = get_running_version()

    if Version.compare(ver, "0.8.30") != :lt do
      data = File.read!(path) |> Jason.decode!()
      globals = ["approved_commands", "projects", "version"]
      {projects, globals_map} = Enum.split_with(data, fn {k, _v} -> k not in globals end)

      if Map.has_key?(data, "projects") do
        :ok
      else
        new_data =
          globals_map
          |> Map.new()
          |> Map.put("projects", Map.new(projects))
          |> Map.put("version", "0.8.30")
          |> Map.put_new("approved_commands", %{})

        File.write!(path, Jason.encode!(new_data, pretty: true))
      end
    end
  end

  @doc """
  Get the path to the store root directory.
  """
  @spec home() :: binary
  def home() do
    path = "#{System.get_env("HOME")}/.fnord"
    File.mkdir_p!(path)
    path
  end

  @doc """
  Get the path to the settings file. If the file does not exist, it will be
  created.
  """
  @spec settings_file() :: binary
  def settings_file() do
    path = "#{home()}/settings.json"

    if !File.exists?(path) do
      File.write!(path, "{}")
    end

    path
  end

  @doc """
  Get a value from the settings store.
  """
  @spec get(t, binary, any()) :: any()
  def get(settings, key, default \\ nil) do
    key = make_key(key)
    Map.get(settings.data, key, default)
  end

  @doc """
  Set a value in the settings store.
  """
  @spec set(t, binary, any()) :: t()
  def set(settings, key, value) do
    key = make_key(key)

    %Settings{settings | data: Map.put(settings.data, key, value)}
    |> spew()
  end

  @doc """
  Delete a value from the settings store.
  """
  @spec delete(t, binary) :: t()
  def delete(settings, key) do
    key = make_key(key)

    %Settings{settings | data: Map.delete(settings.data, key)}
    |> spew()
  end

  @doc """
  Set the project name for the --project option.
  """
  @spec set_project(binary) :: :ok
  def set_project(project_name) do
    Application.put_env(:fnord, :project, project_name)
    Services.Notes.load_notes()
    :ok
  end

  @doc """
  Set the quiet mode for UI output.
  """
  @spec set_quiet(boolean) :: :ok
  def set_quiet(quiet) when is_boolean(quiet) do
    Application.put_env(:fnord, :quiet, quiet)
    :ok
  end

  @doc """
  Set the number of workers for concurrent operations.
  """
  @spec set_workers(pos_integer) :: :ok
  def set_workers(workers) when is_integer(workers) and workers > 0 do
    Application.put_env(:fnord, :workers, workers)
    :ok
  end

  @doc """
  Check if the --project option is set.
  """
  def project_is_set?() do
    !is_nil(Application.get_env(:fnord, :project))
  end

  @doc """
  Get the project specified with --project. If the project name is not set, an
  error tuple is returned.
  """
  @spec get_selected_project() :: {:ok, binary} | {:error, :project_not_set}
  def get_selected_project() do
    Application.get_env(:fnord, :project)
    |> case do
      nil -> {:error, :project_not_set}
      project -> {:ok, project}
    end
  end

  @spec get_project(t) :: {:ok, map()} | {:error, :project_not_found}
  def get_project(settings) do
    with {:ok, project} <- get_selected_project() do
      case get_project_data(settings, project) do
        nil -> {:error, :project_not_found}
        data -> {:ok, data}
      end
    end
  end

  @doc """
  Get project data from the settings, handling both old and new format.
  """
  @spec get_project_data(t, binary) :: map() | nil
  def get_project_data(settings, project_name) do
    projects_map = get(settings, "projects", %{})

    case Map.get(projects_map, project_name) do
      nil -> get(settings, project_name, nil)
      data -> data
    end
  end

  @spec set_project(t, map()) :: map()
  def set_project(settings, data) do
    with {:ok, project} <- get_selected_project() do
      # Validate that the project name is not a global config key
      unless is_valid_project_name?(project) do
        raise ArgumentError,
              "Cannot use '#{project}' as project name - it conflicts with global configuration"
      end

      set_project_data(settings, project, data)
      data
    else
      {:error, :project_not_set} -> raise "Project not set. Use --project to specify a project."
    end
  end

  @doc """
  Set project data in the settings using the new nested format.
  """
  @spec set_project_data(t, binary, map()) :: t()
  def set_project_data(settings, project_name, data) do
    projects_map = get(settings, "projects", %{})
    updated_projects_map = Map.put(projects_map, project_name, data)
    set(settings, "projects", updated_projects_map)
  end

  @doc """
  Delete project data from the settings, handling both old and new format.
  """
  @spec delete_project_data(t, binary) :: t()
  def delete_project_data(settings, project_name) do
    # Delete from new nested format
    projects_map = get(settings, "projects", %{})
    updated_projects_map = Map.delete(projects_map, project_name)
    settings = set(settings, "projects", updated_projects_map)

    # Also delete from old format for cleanup
    delete(settings, project_name)
  end

  @spec list_projects(t) :: [binary]
  def list_projects(settings) do
    settings
    |> get_projects()
    |> Map.keys()
    |> Enum.sort()
  end

  @spec get_root(t) :: {:ok, binary} | {:error, :not_found}
  def get_root(settings) do
    settings
    |> get_project()
    |> case do
      {:ok, %{"root" => root}} -> {:ok, Path.absname(root)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Get approved commands for global or project scope.
  Returns commands in the new nested format: {"tag": ["cmd1", "cmd2"]}.
  """
  @spec get_approved_commands(t, :global | binary) :: map()
  def get_approved_commands(settings, :global) do
    get(settings, "approved_commands", %{})
  end

  def get_approved_commands(settings, project_name) when is_binary(project_name) do
    case get_project_data(settings, project_name) do
      nil ->
        %{}

      project_data ->
        Map.get(project_data, "approved_commands", %{})
    end
  end

  @doc """
  Add an approved command for a specific tag in global or project scope.
  Uses the new nested format: {"tag": ["cmd1", "cmd2"]}.
  """
  @spec add_approved_command(t, :global | binary, binary, binary) :: t()
  def add_approved_command(settings, scope, tag, command)
      when is_binary(tag) and is_binary(command) do
    commands_map = get_approved_commands(settings, scope)
    current_list = Map.get(commands_map, tag, [])
    updated_list = [command | current_list] |> Enum.uniq()
    updated_map = Map.put(commands_map, tag, updated_list)

    case scope do
      :global ->
        set(settings, "approved_commands", updated_map)

      project_name when is_binary(project_name) ->
        project_data = get_project_data(settings, project_name) || %{}
        updated_project_data = Map.put(project_data, "approved_commands", updated_map)
        set_project_data(settings, project_name, updated_project_data)
    end
  end

  @doc """
  Remove an approved command for a specific tag in global or project scope.
  """
  @spec remove_approved_command(t, :global | binary, binary, binary) :: t()
  def remove_approved_command(settings, scope, tag, command)
      when is_binary(tag) and is_binary(command) do
    commands_map = get_approved_commands(settings, scope)

    case Map.get(commands_map, tag) do
      nil ->
        settings

      current_list ->
        updated_list = List.delete(current_list, command)

        updated_map =
          if Enum.empty?(updated_list) do
            Map.delete(commands_map, tag)
          else
            Map.put(commands_map, tag, updated_list)
          end

        case scope do
          :global ->
            set(settings, "approved_commands", updated_map)

          project_name when is_binary(project_name) ->
            project_data = get_project_data(settings, project_name) || %{}
            updated_project_data = Map.put(project_data, "approved_commands", updated_map)
            set_project_data(settings, project_name, updated_project_data)
        end
    end
  end

  @doc """
  Check if a command is approved for a specific tag.
  """
  @spec is_command_approved?(t, :global | binary, binary, binary) :: boolean()
  def is_command_approved?(settings, scope, tag, command)
      when is_binary(tag) and is_binary(command) do
    commands_map = get_approved_commands(settings, scope)
    tag_commands = Map.get(commands_map, tag, [])
    command in tag_commands
  end

  defp slurp(settings) do
    %Settings{
      settings
      | data: File.read!(settings.path) |> Jason.decode!()
    }
  end

  defp spew(settings) do
    settings = ensure_approved_commands_exist(settings)
    File.write!(settings.path, Jason.encode!(settings.data, pretty: true))
    settings
  end

  @doc """
  Get all project configurations, filtering out global configuration keys.
  Returns a map of project_name => project_config.
  """
  @spec get_projects(t()) :: %{binary() => map()}
  def get_projects(settings) do
    projects_map = get(settings, "projects", %{})

    # Also check old format for backward compatibility
    old_format_projects =
      settings.data
      |> Enum.filter(fn {key, value} ->
        is_valid_project_name?(key) and is_map(value) and Map.has_key?(value, "root")
      end)
      |> Map.new()

    Map.merge(old_format_projects, projects_map)
  end

  @doc """
  Check if a given key represents a valid project name (not a global config key).
  Returns false for global configuration keys like "approved_commands".
  """
  @spec is_valid_project_name?(binary()) :: boolean()
  def is_valid_project_name?(name) when is_binary(name) do
    not Enum.member?(global_config_keys(), name)
  end

  def is_valid_project_name?(_), do: false

  @doc """
  Get the list of global configuration keys that should not be treated as project names.
  """
  @spec global_config_keys() :: [binary()]
  def global_config_keys() do
    ["approved_commands", "projects", "version"]
  end

  defp make_key(key) when is_atom(key), do: Atom.to_string(key)
  defp make_key(key), do: key

  defp ensure_approved_commands_exist(settings) do
    data = settings.data

    data =
      if Map.has_key?(data, "approved_commands") do
        data
      else
        Map.put(data, "approved_commands", %{})
      end

    # Handle projects in new nested format
    projects_map = Map.get(data, "projects", %{})

    updated_projects_map =
      Enum.reduce(projects_map, projects_map, fn {project_name, project_data}, acc ->
        if is_map(project_data) and not Map.has_key?(project_data, "approved_commands") do
          updated_project_data = Map.put(project_data, "approved_commands", %{})
          Map.put(acc, project_name, updated_project_data)
        else
          acc
        end
      end)

    data = Map.put(data, "projects", updated_projects_map)

    # Handle old format projects at root level
    data =
      Enum.reduce(data, data, fn
        {key, project_data}, acc
        when is_map(project_data) and key not in ["approved_commands", "projects", "version"] ->
          if Map.has_key?(project_data, "root") and
               not Map.has_key?(project_data, "approved_commands") do
            updated_project_data = Map.put(project_data, "approved_commands", %{})
            Map.put(acc, key, updated_project_data)
          else
            acc
          end

        _, acc ->
          acc
      end)

    %Settings{settings | data: data}
  end
end
