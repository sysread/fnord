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
end
