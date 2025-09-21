defmodule Settings do
  alias Settings.FileLock
  alias Settings.Instrumentation
  require Logger

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
    Settings.Migrate.cleanup_default_project_dir()
    path = settings_file()

    Settings.Migrate.maybe_migrate_settings(path)

    settings =
      %Settings{path: path}
      |> slurp()

    Instrumentation.init_baseline(settings.data)
    settings
  end

  def get_running_version do
    # Allow version override for testing
    case Services.Globals.get_env(:fnord, :test_version_override) do
      nil -> Application.spec(:fnord, :vsn) |> to_string()
      version -> version
    end
  end

  @doc """
  Get the user's home directory, allowing override for testing.
  """
  @spec get_user_home() :: binary | nil | no_return
  def get_user_home do
    Services.Globals.get_env(:fnord, :test_home_override, System.get_env("HOME"))
    |> case do
      nil -> raise "Could not determine user home directory. Is $HOME set?"
      home -> home
    end
  end

  @doc """
  Get the path to the store root directory.
  """
  @spec fnord_home() :: binary
  def fnord_home() do
    path = "#{get_user_home()}/.fnord"
    File.mkdir_p!(path)
    path
  end

  @doc """
  Get the path to the settings file. If the file does not exist, it will be
  created.
  """
  @spec settings_file() :: binary
  def settings_file() do
    path = "#{fnord_home()}/settings.json"

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
  Set the project name for the --project option.
  """
  @spec set_project(atom | binary) :: :ok
  def set_project(project_name) when is_atom(project_name) do
    project_name |> Atom.to_string() |> set_project()
  end

  def set_project(project_name) do
    Services.Globals.put_env(:fnord, :project, project_name)
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
    Services.Globals.put_env(:fnord, :quiet, !!quiet)
    :ok
  end

  @doc """
  Set the number of workers for concurrent operations.
  """
  @spec set_workers(pos_integer) :: :ok
  def set_workers(workers) when is_integer(workers) and workers > 0 do
    Services.Globals.put_env(:fnord, :workers, workers)
    :ok
  end

  @doc """
  Set edit mode for the application.
  """
  @spec set_edit_mode(boolean) :: :ok
  def set_edit_mode(edit_mode) do
    Services.Globals.put_env(:fnord, :edit_mode, !!edit_mode)
    :ok
  end

  @doc """
  Get current edit mode setting.
  """
  @spec get_edit_mode() :: boolean
  def get_edit_mode() do
    Services.Globals.get_env(:fnord, :edit_mode, false)
  end

  @doc """
  Set auto-approve mode for the application. In this mode, file edits
  are automatically approved without user confirmation.
  """
  @spec set_auto_approve(boolean) :: :ok
  def set_auto_approve(auto_approve) do
    Services.Globals.put_env(:fnord, :auto_approve, !!auto_approve)
    :ok
  end

  @doc """
  Get current auto-approve setting.
  """
  @spec get_auto_approve() :: boolean
  def get_auto_approve() do
    Services.Globals.get_env(:fnord, :auto_approve, false)
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
      {policy, timeout} -> Services.Globals.put_env(:fnord, :auto_policy, {policy, timeout})
      nil -> Services.Globals.delete_env(:fnord, :auto_policy)
    end
  end

  @doc """
  Get current auto-approval policy setting.
  """

  @spec get_auto_policy() :: {:approve, non_neg_integer} | {:deny, non_neg_integer} | nil
  def get_auto_policy() do
    Services.Globals.get_env(:fnord, :auto_policy, nil)
  end

  @doc """
  Set or clear a temporary project root override path. Pass a directory path to
  override or nil to clear the override.
  """
  @spec set_project_root_override(binary | nil) :: :ok
  def set_project_root_override(nil) do
    Services.Globals.delete_env(:fnord, :project_root_override)
    :ok
  end

  def set_project_root_override(path) when is_binary(path) do
    Services.Globals.put_env(:fnord, :project_root_override, path)
    :ok
  end

  @doc """
  Gets the project root override path, or nil if not set.
  """
  @spec get_project_root_override() :: binary | nil
  def get_project_root_override() do
    Services.Globals.get_env(:fnord, :project_root_override, nil)
  end

  @doc """
  Check if hint docs feature is enabled. Defaults to `true` if unset.
  """
  @spec get_hint_docs_enabled?() :: boolean
  def get_hint_docs_enabled?() do
    Services.Globals.get_env(:fnord, :hint_docs_enabled, true)
  end

  @doc """
  Check if automatic injection of hint docs is enabled. Defaults to `true` if unset.
  """
  @spec get_hint_docs_auto_inject?() :: boolean
  def get_hint_docs_auto_inject?() do
    Services.Globals.get_env(:fnord, :hint_docs_auto_inject, true)
  end

  @doc """
  Check if the --project option is set.
  """
  def project_is_set?() do
    !is_nil(Services.Globals.get_env(:fnord, :project))
  end

  @doc """
  Get the project specified with --project. If the project name is not set, an
  error tuple is returned.
  """
  @spec get_selected_project :: {:ok, binary} | {:error, :project_not_set}
  def get_selected_project() do
    Services.Globals.get_env(:fnord, :project)
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
    update(settings, "projects", fn _ -> updated_projects_map end)
  end

  @doc """
  Delete project data from the settings, handling both old and new format.
  """
  @spec delete_project_data(t, binary) :: t
  def delete_project_data(settings, project_name) do
    # Delete from new nested format
    projects_map = get(settings, "projects", %{})
    updated_projects_map = Map.delete(projects_map, project_name)
    settings = update(settings, "projects", fn _ -> updated_projects_map end)

    # Also delete from old format for cleanup
    update(settings, project_name, fn _ -> :delete end)
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

  @doc """
  Atomically update a top-level key in the settings file using a cross-process
  lock and a read-merge-write cycle.

  The updater receives the current value for `key` (or `default` when missing)
  and must return the new value. If the updater returns `:delete`, the key will
  be removed from the settings.
  """
  @spec update(t, binary, (any -> any | :delete), any) :: t
  def update(%Settings{path: path}, key, updater, default \\ %{}) do
    key = make_key(key)

    with_settings_lock(path, fn ->
      before = fresh_read(path)

      new_data =
        before
        |> Map.get(key, default)
        |> updater.()
        |> case do
          :delete -> Map.delete(before, key)
          value -> Map.put(before, key, value)
        end

      after_data = new_data

      Instrumentation.record_trace(:update, key, before, after_data)

      final =
        before
        |> Instrumentation.guard_or_heal(after_data, %{op: :update, key: key})

      final
      |> Jason.encode!(pretty: true)
      |> then(&write_atomic!(path, &1))

      %Settings{path: path, data: final}
    end)
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

  def write_atomic!(path, "") do
    write_atomic!(path, "{}")
  end

  def write_atomic!(path, content) do
    dir = Path.dirname(path)
    base = Path.basename(path)

    # Create temp file in the same directory to avoid cross-device rename
    # issues and preserve atomicity.
    tmp = Path.join(dir, ".#{base}.#{System.unique_integer([:positive])}.tmp")

    File.write!(tmp, content)
    File.rename!(tmp, path)
    :ok
  end

  # ----------------------------------------------------------------------------
  # Concurrency-safe update helpers
  # ----------------------------------------------------------------------------
  defp with_settings_lock(path, fun) when is_function(fun, 0) do
    lock_path = Path.expand(path)

    try do
      FileLock.acquire_lock!(lock_path)
      fun.()
    after
      # Release global lock first, then filesystem lock
      FileLock.release_lock!(lock_path)
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

  defp make_key(key) when is_atom(key), do: Atom.to_string(key)
  defp make_key(key), do: key
end
