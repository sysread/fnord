defmodule Settings do
  defstruct [:path, :data]

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new() do
    cleanup_default_project_dir()

    %Settings{path: settings_file()}
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
    NotesServer.load_notes()
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
      case get(settings, project, nil) do
        nil -> {:error, :project_not_found}
        data -> {:ok, data}
      end
    end
  end

  @spec set_project(t, map()) :: map()
  def set_project(settings, data) do
    with {:ok, project} <- get_selected_project() do
      set(settings, project, data)
      data
    else
      {:error, :project_not_set} -> raise "Project not set. Use --project to specify a project."
    end
  end

  @spec list_projects(t) :: [binary]
  def list_projects(settings) do
    settings.data
    |> Map.keys()
    |> Enum.reject(&(&1 == "approved_commands"))
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
  """
  @spec get_approved_commands(t, :global | binary) :: map()
  def get_approved_commands(settings, :global) do
    get(settings, "approved_commands", %{})
  end

  def get_approved_commands(settings, project_name) when is_binary(project_name) do
    case get(settings, project_name) do
      nil -> %{}
      project_data -> Map.get(project_data, "approved_commands", %{})
    end
  end

  @doc """
  Set approval status for a command in global or project scope.
  """
  @spec set_command_approval(t, :global | binary, binary, boolean) :: t()
  def set_command_approval(settings, :global, command, approved)
      when is_binary(command) and is_boolean(approved) do
    current_commands = get_approved_commands(settings, :global)
    updated_commands = Map.put(current_commands, command, approved)
    set(settings, "approved_commands", updated_commands)
  end

  def set_command_approval(settings, project_name, command, approved)
      when is_binary(project_name) and is_binary(command) and is_boolean(approved) do
    project_data = get(settings, project_name, %{})
    current_commands = Map.get(project_data, "approved_commands", %{})
    updated_commands = Map.put(current_commands, command, approved)
    updated_project_data = Map.put(project_data, "approved_commands", updated_commands)
    set(settings, project_name, updated_project_data)
  end

  @doc """
  Remove a command from approved commands list in global or project scope.
  """
  @spec remove_command_approval(t, :global | binary, binary) :: t()
  def remove_command_approval(settings, :global, command) when is_binary(command) do
    current_commands = get_approved_commands(settings, :global)
    updated_commands = Map.delete(current_commands, command)
    set(settings, "approved_commands", updated_commands)
  end

  def remove_command_approval(settings, project_name, command)
      when is_binary(project_name) and is_binary(command) do
    project_data = get(settings, project_name, %{})
    current_commands = Map.get(project_data, "approved_commands", %{})
    updated_commands = Map.delete(current_commands, command)
    updated_project_data = Map.put(project_data, "approved_commands", updated_commands)
    set(settings, project_name, updated_project_data)
  end

  @doc """
  Get approval status for a command. Checks project scope first, then falls back to global.
  """
  @spec get_command_approval(t, binary, binary) :: {:ok, boolean} | {:error, :not_found}
  def get_command_approval(settings, project_name, command)
      when is_binary(project_name) and is_binary(command) do
    project_commands = get_approved_commands(settings, project_name)
    global_commands = get_approved_commands(settings, :global)

    case {Map.get(project_commands, command), Map.get(global_commands, command)} do
      {project_approval, _} when is_boolean(project_approval) -> {:ok, project_approval}
      {nil, global_approval} when is_boolean(global_approval) -> {:ok, global_approval}
      {nil, nil} -> {:error, :not_found}
    end
  end

  @doc """
  Get approval status for a command in global scope only.
  """
  @spec get_global_command_approval(t, binary) :: {:ok, boolean} | {:error, :not_found}
  def get_global_command_approval(settings, command) when is_binary(command) do
    global_commands = get_approved_commands(settings, :global)

    case Map.get(global_commands, command) do
      approval when is_boolean(approval) -> {:ok, approval}
      nil -> {:error, :not_found}
    end
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

    data =
      Enum.reduce(data, data, fn
        {key, project_data}, acc when is_map(project_data) and key != "approved_commands" ->
          if Map.has_key?(project_data, "approved_commands") do
            acc
          else
            updated_project_data = Map.put(project_data, "approved_commands", %{})
            Map.put(acc, key, updated_project_data)
          end

        _, acc ->
          acc
      end)

    %Settings{settings | data: data}
  end
end
