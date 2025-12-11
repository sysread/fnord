defmodule Store.Project.FilesDirMigration do
  @moduledoc """
  Migrates legacy entry directories into the new files/ layout.

  Moves or merges each entry directory under the project store path into
  an entry-specific directory under files_root. Preserves existing files in
  target directories, merges missing files, and removes legacy directories.

  Ignores root-level "files" and "conversations" directories.
  """

  @spec ensure_files_dir_layout(Store.Project.t()) :: :ok
  def ensure_files_dir_layout(%Store.Project{} = project) do
    files_root = Store.Project.files_root(project)
    migrate(project.store_path, files_root)
  end

  def migrate(store_path, files_root) when is_binary(store_path) and is_binary(files_root) do
    lock_key = Path.join(store_path, ".files_dir_migration")

    FileLock.with_lock(
      lock_key,
      fn ->
        # Ensure the files_root exists
        File.mkdir_p!(files_root)

        # Find legacy entry directories at the project root
        legacy_paths =
          store_path
          |> Path.join("*")
          |> Path.wildcard()
          |> Enum.filter(fn path ->
            File.dir?(path) and
              Path.basename(path) not in ["files", "conversations"] and
              File.exists?(Path.join(path, "metadata.json"))
          end)

        # For each legacy directory, move or merge into files_root
        Enum.each(legacy_paths, fn legacy_path ->
          basename = Path.basename(legacy_path)
          target_path = Path.join(files_root, basename)

          if not File.exists?(target_path) do
            File.rename!(legacy_path, target_path)
          else
            for filename <- ["metadata.json", "summary", "outline", "embeddings.json"] do
              src = Path.join(legacy_path, filename)
              dest = Path.join(target_path, filename)

              if File.exists?(src) and not File.exists?(dest) do
                File.rename!(src, dest)
              end
            end

            # Remove the now-empty legacy directory
            File.rm_rf!(legacy_path)
          end
        end)

        :ok
      end,
      []
    )
    |> case do
      {:ok, :ok} -> :ok
      {:error, :lock_failed} -> :ok
    end
  end
end
