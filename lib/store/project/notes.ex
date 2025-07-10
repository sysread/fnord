defmodule Store.Project.Notes do
  @filename "notes.md"

  def file_path do
    with {:ok, project} <- Store.get_project() do
      {:ok, Path.join(project.store_path, @filename)}
    end
  end

  def reset do
    with {:ok, path} <- file_path() do
      if File.exists?(path), do: File.rm_rf(path)
      :ok
    end
  end

  def write(content) do
    with {:ok, file} <- file_path() do
      File.write(file, content)
    end
  end

  def read do
    with {:ok, file} <- file_path(),
         {:ok, notes} <- File.read(file) do
      {:ok, notes}
    else
      {:error, :enoent} -> {:error, :no_notes}
      other -> other
    end
  end
end
