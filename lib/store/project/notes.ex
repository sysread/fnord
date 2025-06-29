defmodule Store.Project.Notes do
  @filename "notes.md"

  def file_path() do
    with {:ok, project} <- Store.get_project() do
      {:ok, Path.join(project.store_path, @filename)}
    end
  end

  def reset() do
    with {:ok, path} <- file_path() do
      if File.exists?(path) do
        File.rm_rf(path)
      end

      :ok
    end
  end

  def write(content) do
    with {:ok, file} <- file_path() do
      File.write(file, content)
    end
  end

  def read() do
    with_flock(:shared, &do_read/0)
  end

  def with_flock(kind, func) when kind in [:shared, :exclusive] and is_function(func, 0) do
    with {:ok, path} <- file_path() do
      lock_path = path <> ".lock"

      case kind do
        :shared ->
          wait_unlock(lock_path)
          func.()

        :exclusive ->
          file = acquire_exclusive(lock_path)

          try do
            func.()
          after
            File.close(file)
            File.rm(lock_path)
          end
      end
    end
  end

  defp do_read() do
    with {:ok, file} <- file_path() do
      file
      |> File.read()
      |> case do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:error, :no_notes}
        other -> other
      end
    end
  end

  defp wait_unlock(lock_path) do
    if File.exists?(lock_path) do
      Process.sleep(10)
      wait_unlock(lock_path)
    else
      :ok
    end
  end

  defp acquire_exclusive(lock_path) do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, file} ->
        file

      {:error, _reason} ->
        wait_unlock(lock_path)
        acquire_exclusive(lock_path)
    end
  end
end
