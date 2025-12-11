defmodule Store.Project.Entry.MigrateAbsToRelPathKeys do
  @moduledoc """
  Handles migration of project store entries from absolute-path-based IDs to relative-path-based IDs.

  This module provides functionality to:
  - Detect when migration is needed for entry ID scheme changes
  - Coordinate cross-process migration with lockfiles
  - Migrate entry directories and metadata files from absolute-path keys to relative-path keys
  - Ensure entries use relative paths for portability across machines
  """

  @doc """
  Ensures that all entries in the project use relative-path based IDs.

  This function is idempotent and safe to call multiple times. It uses a lockfile
  to prevent concurrent migrations and will raise if another process is already
  performing the migration.
  """
  @spec ensure_relative_entry_ids(Store.Project.t()) :: :ok
  def ensure_relative_entry_ids(project) do
    files_root = Store.Project.files_root(project)
    lockfile_path = Path.join(files_root, ".migration_in_progress")

    case check_migration_lock(lockfile_path) do
      :no_migration_needed ->
        :ok

      :migration_needed ->
        create_migration_lock(lockfile_path)

        try do
          migrate_legacy_entries(project)
        after
          remove_migration_lock(lockfile_path)
        end

      {:migration_in_progress, pid} ->
        raise "Store upgrade in progress by process #{pid}. Please wait a moment and retry your command."
    end
  end

  # Private functions for migration logic

  defp check_migration_lock(lockfile_path) do
    cond do
      not File.exists?(lockfile_path) ->
        # No lockfile, check if migration is needed
        if migration_needed?(Path.dirname(lockfile_path)) do
          :migration_needed
        else
          :no_migration_needed
        end

      true ->
        # Lockfile exists, check if PID is alive
        case File.read(lockfile_path) do
          {:ok, pid_str} ->
            case Integer.parse(String.trim(pid_str)) do
              {pid, ""} ->
                # Reentrant: our own PID holds the lock
                if to_string(pid) == to_string(System.pid()) do
                  :no_migration_needed
                else
                  if process_alive?(pid) do
                    {:migration_in_progress, pid}
                  else
                    stale_lock_retry(lockfile_path)
                  end
                end

              _ ->
                # Invalid lockfile, remove and proceed
                stale_lock_retry(lockfile_path)
            end

          {:error, _} ->
            # Can't read lockfile, remove and proceed
            stale_lock_retry(lockfile_path)
        end
    end
  end

  defp stale_lock_retry(lockfile_path) do
    File.rm(lockfile_path)

    if migration_needed?(Path.dirname(lockfile_path)) do
      :migration_needed
    else
      :no_migration_needed
    end
  end

  defp migration_needed?(store_path) do
    # Quick check: any legacy hex-named directories?
    legacy_hex? =
      store_path
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.any?(fn dir -> Path.basename(dir) =~ ~r/^[0-9a-f]{64}$/ end)

    if legacy_hex? do
      true
    else
      # Otherwise, check if any metadata.json contains an absolute path
      store_path
      |> Path.join("*/metadata.json")
      |> Path.wildcard()
      |> Enum.any?(fn metadata_file ->
        case File.read(metadata_file) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, %{"file" => file_path}} when is_binary(file_path) ->
                String.starts_with?(file_path, "/")

              _ ->
                false
            end

          {:error, _} ->
            false
        end
      end)
    end
  end

  defp process_alive?(pid) do
    case :os.find_executable(~c"ps") do
      false ->
        # If ps is not available, assume process is dead
        false

      _ ->
        try do
          {output, exit_code} = System.cmd("ps", ["-p", to_string(pid)])
          exit_code == 0 and String.contains?(output, to_string(pid))
        rescue
          _ -> false
        end
    end
  end

  defp create_migration_lock(lockfile_path) do
    File.mkdir_p!(Path.dirname(lockfile_path))
    File.write!(lockfile_path, to_string(System.pid()))
  end

  defp remove_migration_lock(lockfile_path) do
    File.rm(lockfile_path)
  end

  defp migrate_legacy_entries(project) do
    # Find all entry directories with metadata.json
    files_root = Store.Project.files_root(project)

    metadata_files =
      files_root
      |> Path.join("*/metadata.json")
      |> Path.wildcard()

    Enum.each(metadata_files, fn metadata_file ->
      entry_dir = Path.dirname(metadata_file)
      migrate_entry_if_needed(project, entry_dir, metadata_file)
    end)
  end

  defp migrate_entry_if_needed(project, entry_dir, metadata_file) do
    with {:ok, content} <- File.read(metadata_file),
         {:ok, metadata} <- Jason.decode(content),
         {:ok, file_path} <- Map.fetch(metadata, "file") do
      cond do
        # New relative path but wrong dir name -> rename to expected reversible ID
        is_binary(file_path) and not String.starts_with?(file_path, "/") ->
          files_root = Store.Project.files_root(project)
          expected_id = Store.Project.Entry.id_for_rel_path(file_path)
          current_id = Path.basename(entry_dir)
          expected_dir = Path.join(files_root, expected_id)

          if current_id != expected_id do
            if File.exists?(expected_dir) do
              merge_dirs(entry_dir, expected_dir)
            else
              File.rename!(entry_dir, expected_dir)
              # metadata already relative; fine as-is
            end
          end

          :ok

        # Legacy absolute path that needs migration
        is_binary(file_path) and String.starts_with?(file_path, "/") ->
          migrate_entry(project, entry_dir, metadata_file, file_path, metadata)

        true ->
          # Invalid or missing file field
          UI.warn("Invalid metadata in #{metadata_file}, skipping migration")
          :ok
      end
    else
      error ->
        UI.warn("Could not read metadata from #{metadata_file}: #{inspect(error)}")
        :ok
    end
  end

  defp migrate_entry(project, old_entry_dir, metadata_file, abs_file_path, metadata) do
    files_root = Store.Project.files_root(project)

    # Calculate relative path and new entry ID
    case Path.relative_to(abs_file_path, project.source_root) do
      ^abs_file_path ->
        # File is outside source root, delete this entry
        UI.info("Removing entry for file outside source root: #{abs_file_path}")
        File.rm_rf!(old_entry_dir)

      rel_path ->
        # File is within source root, migrate it
        new_entry_id = Store.Project.Entry.id_for_rel_path(rel_path)
        new_entry_dir = Path.join(files_root, new_entry_id)

        # Skip if already migrated (shouldn't happen, but be safe)
        if old_entry_dir == new_entry_dir do
          # Just update the metadata
          update_metadata_to_relative_path(metadata_file, rel_path, metadata)
        else
          # Rename directory and update metadata
          if File.exists?(new_entry_dir) do
            merge_dirs(old_entry_dir, new_entry_dir)
          else
            File.rename!(old_entry_dir, new_entry_dir)
            new_metadata_file = Path.join(new_entry_dir, "metadata.json")
            update_metadata_to_relative_path(new_metadata_file, rel_path, metadata)
          end
        end
    end
  end

  defp merge_dirs(from_dir, to_dir) do
    for name <- ["summary", "outline", "embeddings.json"] do
      src = Path.join(from_dir, name)
      dst = Path.join(to_dir, name)
      if File.exists?(src) and !File.exists?(dst), do: File.cp!(src, dst)
    end

    File.rm_rf!(from_dir)
  end

  defp update_metadata_to_relative_path(metadata_file, rel_path, metadata) do
    updated_metadata = Map.put(metadata, "file", rel_path)

    case Jason.encode(updated_metadata) do
      {:ok, json} ->
        File.write!(metadata_file, json)

      {:error, reason} ->
        UI.warn("Failed to encode updated metadata for #{metadata_file}: #{inspect(reason)}")
    end
  end
end
