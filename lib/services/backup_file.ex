defmodule Services.BackupFile do
  @moduledoc """
  GenServer that manages backup file creation for file editing operations with dual counter system.

  Backup files follow the naming pattern:
  `original_filename.global_session_counter.change_counter.bak`

  - global_session_counter: Per-file, per-OS-process counter that increments when
    existing backup files from previous processes are detected
  - change_counter: Per-file counter that increments for each successful edit
    within the current session
  """

  use Agent

  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  @type state :: %{
          global_counters: %{binary => non_neg_integer},
          change_counters: %{binary => non_neg_integer},
          backup_files: [binary]
        }

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  @doc """
  Starts the backup file server with a globally registered name.
  """
  @spec start_link(keyword) :: {:ok, pid} | {:error, term}
  def start_link(_opts \\ []) do
    Agent.start_link(&initial_state/0, name: __MODULE__)
  end

  @doc """
  Creates a backup file for the given file path and returns the backup path.
  Uses the dual counter system to generate unique backup filenames.
  """
  @spec create_backup(binary) :: {:ok, binary} | {:error, term}
  def create_backup(file_path) do
    Agent.get_and_update(__MODULE__, fn state ->
      case do_create_backup(file_path, state) do
        {:ok, backup_path, new_state} ->
          {{:ok, backup_path}, new_state}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end)
  end

  @doc """
  Returns all backup files created during this session (current OS process).

  This includes backup files for all edited files during the current session,
  but excludes any backup files that may exist from previous sessions.

  Files are returned in reverse chronological order (most recent first).
  """
  @spec get_session_backups() :: [binary]
  def get_session_backups do
    Agent.get(__MODULE__, fn state -> state.backup_files end)
  end

  @doc """
  Resets the server state. Primarily used for testing.
  """
  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _state -> initial_state() end)
  end

  @doc """
  Offers to cleanup backup files created during this session.

  If backup files exist, lists them and prompts the user for confirmation
  before deleting them. If no backup files exist, does nothing silently.
  """
  @spec offer_cleanup() :: :ok
  def offer_cleanup do
    backup_files = get_session_backups()

    if Enum.empty?(backup_files) do
      :ok
    else
      backup_file_list =
        backup_files
        |> Enum.reverse()
        |> Enum.map(&"- #{&1}")
        |> Enum.join("\n")

      UI.warning_banner("Backup files were created during this session")
      UI.say(backup_file_list)

      if UI.confirm("Would you like to delete these backup files?") do
        cleanup_session_backups(backup_files)
      else
        UI.say("_Backup files not deleted. They may be removed at your convenience._")
      end
    end
  end

  @doc """
  Delete all backup files created during this session.
  """
  @spec cleanup_backup_files() :: :ok
  def cleanup_backup_files do
    backup_files = get_session_backups()
    cleanup_session_backups(backup_files)
    reset()
  end

  @doc """
  Checks if a file path represents a backup file created by fnord.
  Returns true if the filename matches the pattern: filename.X.Y.bak
  """
  @spec is_backup_file?(binary) :: boolean
  def is_backup_file?(path) do
    basename = Path.basename(path)
    String.match?(basename, ~r/\.\d+\.\d+\.bak$/)
  end

  @doc """
  Checks if a backup file was created during the current session.
  Returns true if the file exists in the current session's backup list.
  """
  @spec is_session_backup?(binary) :: boolean
  def is_session_backup?(path) do
    with {:ok, project} <- Store.get_project() do
      absolute_path = Store.Project.expand_path(path, project)
      absolute_path in get_session_backups()
    else
      _ -> false
    end
  end

  @doc """
  Returns a descriptive note for backup files, or nil for non-backup files.
  Includes session information if the backup was created this session.
  """
  @spec describe_backup(binary) :: binary | nil
  def describe_backup(path) do
    if is_backup_file?(path) do
      session_note =
        if is_session_backup?(path),
          do: " (created this session)",
          else: ""

      "[fnord backup file#{session_note}]"
    else
      nil
    end
  end

  # ----------------------------------------------------------------------------
  # Private Functions
  # ----------------------------------------------------------------------------
  @spec initial_state() :: state
  defp initial_state do
    %{
      global_counters: %{},
      change_counters: %{},
      backup_files: []
    }
  end

  @spec do_create_backup(binary, state) ::
          {:ok, binary, state} | {:error, term}
  defp do_create_backup(file_path, state) do
    with {:ok, global_counter} <- get_or_initialize_global_counter(file_path, state),
         change_counter <- get_change_counter(file_path, state),
         backup_path <- build_backup_path(file_path, global_counter, change_counter),
         :ok <- copy_file_to_backup(file_path, backup_path) do
      new_state = %{
        state
        | global_counters: Map.put(state.global_counters, file_path, global_counter),
          change_counters: Map.put(state.change_counters, file_path, change_counter + 1),
          backup_files: [backup_path | state.backup_files]
      }

      {:ok, backup_path, new_state}
    end
  end

  @spec get_or_initialize_global_counter(binary, state) ::
          {:ok, non_neg_integer} | {:error, term}
  defp get_or_initialize_global_counter(file_path, state) do
    case Map.get(state.global_counters, file_path) do
      nil ->
        {:ok, find_next_global_counter(file_path)}

      counter ->
        {:ok, counter}
    end
  end

  @spec get_change_counter(binary, state) :: non_neg_integer
  defp get_change_counter(file_path, state) do
    Map.get(state.change_counters, file_path, 0)
  end

  @spec find_next_global_counter(binary) :: non_neg_integer
  defp find_next_global_counter(file_path) do
    case find_existing_backup_pattern(file_path) do
      [] -> 0
      existing_counters -> Enum.max(existing_counters) + 1
    end
  end

  @spec find_existing_backup_pattern(binary) :: [non_neg_integer]
  defp find_existing_backup_pattern(file_path) do
    dir = Path.dirname(file_path)
    base_name = Path.basename(file_path)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.match?(&1, ~r/^#{Regex.escape(base_name)}\.(\d+)\.(\d+)\.bak$/))
        |> Enum.map(&extract_global_counter(&1, base_name))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @spec extract_global_counter(binary, binary) :: non_neg_integer | nil
  defp extract_global_counter(filename, base_name) do
    regex = ~r/^#{Regex.escape(base_name)}\.(\d+)\.(\d+)\.bak$/

    case Regex.run(regex, filename) do
      [_, global_str, _change_str] ->
        String.to_integer(global_str)

      _ ->
        nil
    end
  end

  @spec build_backup_path(binary, non_neg_integer, non_neg_integer) :: binary
  defp build_backup_path(file_path, global_counter, change_counter) do
    "#{file_path}.#{global_counter}.#{change_counter}.bak"
  end

  @spec copy_file_to_backup(binary, binary) :: :ok | {:error, term}
  defp copy_file_to_backup(source_path, backup_path) do
    case File.exists?(source_path) do
      true -> File.cp(source_path, backup_path)
      false -> {:error, :source_file_not_found}
    end
  end

  @spec cleanup_session_backups([binary]) :: :ok
  defp cleanup_session_backups(backup_files) do
    {deleted_count, failed_files} =
      backup_files
      |> Enum.reduce({0, []}, fn backup_file, {deleted, failed} ->
        case File.rm(backup_file) do
          :ok ->
            UI.debug("Deleted backup file", Path.basename(backup_file))
            {deleted + 1, failed}

          {:error, reason} ->
            UI.warn("Failed to delete backup file", "#{Path.basename(backup_file)}: #{reason}")
            {deleted, [Path.basename(backup_file) | failed]}
        end
      end)

    if Enum.empty?(failed_files) do
      UI.info("Successfully deleted #{deleted_count} backup file(s)")
    else
      failed_files
      |> Enum.reverse()
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")
      |> then(&UI.warn("Unable to delete some backup files", &1))
    end
  end
end
