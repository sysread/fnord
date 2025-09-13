defmodule Settings do
  # ----------------------------------------------------------------------------
  # Settings type
  # ----------------------------------------------------------------------------
  defstruct [:path, :data]

  @type t :: %__MODULE__{
          path: binary,
          data: map
        }

  @spec new() :: t
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
      data =
        with {:ok, content} <- File.read(path),
             {:ok, parsed} <- Jason.decode(content) do
          parsed
        else
          _ ->
            raise """
            Corrupted settings file: #{path}

            You may need to reset your fnord settings. Consider backing up the file
            and running 'fnord init' to recreate it.
            """
        end

      globals = ["approvals", "projects", "version"]
      {projects, globals_map} = Enum.split_with(data, fn {k, _v} -> k not in globals end)

      if Map.has_key?(data, "projects") do
        :ok
      else
        new_data =
          globals_map
          |> Map.new()
          |> Map.put("projects", Map.new(projects))
          |> Map.put("version", "0.8.30")
          |> Map.put_new("approvals", %{})

        write_atomic!(path, Jason.encode!(new_data, pretty: true))
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
      write_atomic!(path, "{}")
    end

    path
  end

  @doc """
  Get a value from the settings store.
  """
  @spec get(t, binary, any) :: any
  def get(settings, key, default \\ nil) do
    key = make_key(key)
    Map.get(settings.data, key, default)
  end

  @doc """
  Set a value in the settings store.
  """
  @spec set(t, binary, any) :: t
  def set(settings, key, value) do
    key = make_key(key)

    %Settings{settings | data: Map.put(settings.data, key, value)}
    |> spew()
  end

  @doc """
  Delete a value from the settings store.
  """
  @spec delete(t, binary) :: t
  def delete(settings, key) do
    key = make_key(key)

    %Settings{settings | data: Map.delete(settings.data, key)}
    |> spew()
  end

  @doc """
  Set the project name for the --project option.
  """
  @spec set_project(atom | binary) :: :ok
  def set_project(project_name) when is_atom(project_name) do
    project_name |> Atom.to_string() |> set_project()
  end

  def set_project(project_name) do
    Application.put_env(:fnord, :project, project_name)
    UI.debug("Project selected", project_name)
    Services.Notes.load_notes()
    :ok
  end

  @doc """
  Set the quiet mode for UI output.
  """
  @spec set_quiet(boolean) :: :ok
  def set_quiet(quiet) do
    # Force quiet mode to be a boolean
    Application.put_env(:fnord, :quiet, !!quiet)
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
  Set edit mode for the application.
  """
  @spec set_edit_mode(boolean) :: :ok
  def set_edit_mode(edit_mode) do
    Application.put_env(:fnord, :edit_mode, !!edit_mode)
    :ok
  end

  @doc """
  Get current edit mode setting.
  """
  @spec get_edit_mode() :: boolean
  def get_edit_mode() do
    Application.get_env(:fnord, :edit_mode, false)
  end

  @doc """
  Set auto-approve mode for the application. In this mode, file edits
  are automatically approved without user confirmation.
  """
  @spec set_auto_approve(boolean) :: :ok
  def set_auto_approve(auto_approve) do
    Application.put_env(:fnord, :auto_approve, !!auto_approve)
    :ok
  end

  @doc """
  Get current auto-approve setting.
  """
  @spec get_auto_approve() :: boolean
  def get_auto_approve() do
    Application.get_env(:fnord, :auto_approve, false)
  end

  @doc """
  Set auto-approval policy for the application. This setting controls how
  unattended approvals are handled.

  The `policy` is a tuple consisting of an action and a timeout (or `nil` to
  disable):
  - `:approve` to automatically approve changes after a timeout.
  - `:deny` to automatically deny changes after a timeout.
  - `nil` to disable auto-approval.

  The `timeout` is specified in milliseconds and determines how long to wait
  before applying the auto-approval policy.

  When an approval is required, the system will first send a notification to
  the user after 60 seconds. If the user does not respond within the timeout
  specified by the auto-approval policy, the specified action will be taken
  automatically.
  """
  @spec set_auto_policy({:approve | :deny, non_neg_integer} | nil) :: :ok
  def set_auto_policy(policy) do
    case policy do
      {policy, timeout} -> Application.put_env(:fnord, :auto_policy, {policy, timeout})
      nil -> Application.delete_env(:fnord, :auto_policy)
    end
  end

  @doc """
  Get current auto-approval policy setting.
  """

  @spec get_auto_policy() :: {:approve, non_neg_integer} | {:deny, non_neg_integer} | nil
  def get_auto_policy() do
    Application.get_env(:fnord, :auto_policy, nil)
  end

  @doc """
  Set or clear a temporary project root override path. Pass a directory path to
  override or nil to clear the override.
  """
  @spec set_project_root_override(binary | nil) :: :ok
  def set_project_root_override(nil) do
    Application.delete_env(:fnord, :project_root_override)
    :ok
  end

  def set_project_root_override(path) when is_binary(path) do
    Application.put_env(:fnord, :project_root_override, path)
    :ok
  end

  @doc """
  Gets the project root override path, or nil if not set.
  """
  @spec get_project_root_override() :: binary | nil
  def get_project_root_override() do
    Application.get_env(:fnord, :project_root_override, nil)
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
  @spec get_selected_project :: {:ok, binary} | {:error, :project_not_set}
  def get_selected_project() do
    Application.get_env(:fnord, :project)
    |> case do
      nil -> {:error, :project_not_set}
      project -> {:ok, project}
    end
  end

  @spec get_project(t) :: {:ok, map} | {:error, :project_not_found}
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
  @spec get_project_data(t, binary) :: map | nil
  def get_project_data(settings, project_name) do
    projects_map = get(settings, "projects", %{})

    case Map.get(projects_map, project_name) do
      # Old style project data in the root of the settings object
      nil -> get(settings, project_name, nil)
      data -> data
    end
    |> case do
      nil -> nil
      data -> Map.put(data, "name", project_name)
    end
  end

  @spec set_project(t, map) :: map
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
  @spec set_project_data(t, binary, map) :: t
  def set_project_data(settings, project_name, data) do
    projects_map = get(settings, "projects", %{})
    updated_projects_map = Map.put(projects_map, project_name, data)
    set(settings, "projects", updated_projects_map)
  end

  @doc """
  Delete project data from the settings, handling both old and new format.
  """
  @spec delete_project_data(t, binary) :: t
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
    |> get_project
    |> case do
      {:ok, %{"root" => root}} -> {:ok, Path.absname(root)}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp slurp(settings) do
    data =
      with {:ok, content} <- File.read(settings.path),
           {:ok, parsed} <- Jason.decode(content) do
        parsed
      else
        _ ->
          raise """
          Corrupted settings file: #{settings.path}

          You may need to reset your fnord settings. Consider backing up the file
          and running 'fnord init' to recreate it.
          """
      end

    %Settings{settings | data: data}
  end

  defp spew(settings) do
    settings = ensure_approvals_exist(settings)
    json = Jason.encode!(settings.data, pretty: true)
    write_atomic!(settings.path, json)
    settings
  end

  defp write_atomic!(path, "") do
    write_atomic!(path, "{}")
  end

  defp write_atomic!(path, content) do
    dir = Path.dirname(path)
    base = Path.basename(path)

    # Create temp file in the same directory to avoid cross-device rename
    # issues and preserve atomicity.
    tmp = Path.join(dir, ".#{base}.#{System.unique_integer([:positive])}.tmp")

    File.write!(tmp, content)
    File.rename!(tmp, path)
    :ok
  end

  @doc """
  Get all project configurations.
  Returns a map of project_name => project_config.
  """
  @spec get_projects(t) :: %{binary => map}
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
  Returns false for global configuration keys like "approvals".
  """
  @spec is_valid_project_name?(binary) :: boolean
  def is_valid_project_name?(name) when is_binary(name) do
    not Enum.member?(global_config_keys(), name)
  end

  def is_valid_project_name?(_), do: false

  @doc """
  Get the list of global configuration keys that should not be treated as project names.
  """
  @spec global_config_keys() :: [binary]
  def global_config_keys() do
    ["approvals", "projects", "version"]
  end

  defp make_key(key) when is_atom(key), do: Atom.to_string(key)
  defp make_key(key), do: key

  defp ensure_approvals_exist(settings) do
    data = settings.data

    data =
      if Map.has_key?(data, "approvals") do
        data
      else
        Map.put(data, "approvals", %{})
      end

    # Handle projects in new nested format
    projects_map = Map.get(data, "projects", %{})

    updated_projects_map =
      Enum.reduce(projects_map, projects_map, fn {project_name, project_data}, acc ->
        if is_map(project_data) and not Map.has_key?(project_data, "approvals") do
          updated_project_data = Map.put(project_data, "approvals", %{})
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
        when is_map(project_data) and key not in ["approvals", "projects", "version"] ->
          if Map.has_key?(project_data, "root") and
               not Map.has_key?(project_data, "approvals") do
            updated_project_data = Map.put(project_data, "approvals", %{})
            Map.put(acc, key, updated_project_data)
          else
            acc
          end

        _, acc ->
          acc
      end)

    %Settings{settings | data: data}
  end

  @doc """
  Check if model performance debugging is enabled via environment variable.
  """
  @spec debug_models?() :: boolean
  def debug_models?() do
    case System.get_env("FNORD_DEBUG_MODELS") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  # ----------------------------------------------------------------------------
  # Concurrency-safe update helpers
  # ----------------------------------------------------------------------------
  defp with_settings_lock(path, fun) when is_function(fun, 0) do
    resource = {:fnord_settings_lock, Path.expand(path)}
    requester = self()
    id = {resource, requester}

    try do
      true = :global.set_lock(id, [node()])
      fun.()
    after
      true = :global.del_lock(id, [node()])
    end
  end

  # Read the latest JSON from disk ignoring the cached struct data.
  defp fresh_read(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc """
  Atomically update a top-level key in the settings file using a
  cross-process lock and a read-merge-write cycle.

  The updater receives the current value for `key` (or `default` when missing)
  and must return the new value.
  """
  @spec update(t, binary, (any -> any), any) :: t
  def update(%Settings{path: path} = _settings, key, updater, default \\ %{})
      when is_function(updater, 1) do
    with_settings_lock(path, fn ->
      data = fresh_read(path)
      cur = Map.get(data, make_key(key), default)
      new_val = updater.(cur)
      new_data = Map.put(data, make_key(key), new_val)
      json = Jason.encode!(new_data, pretty: true)
      write_atomic!(path, json)
      %Settings{path: path, data: new_data}
    end)
  end
end
