defmodule Store.Project.Notes do
  @filename "notes.md"

  def file_path do
    with {:ok, project} <- Store.get_project() do
      file_path(project)
    end
  end

  @doc """
  Returns the notes file path for the given project.

  The project may be provided as a `%Store.Project{}` or as a project name
  binary, which will be resolved via `Store.get_project/1`.
  """
  @spec file_path(Store.Project.t() | binary()) :: {:ok, String.t()} | {:error, term()}
  def file_path(project) do
    with {:ok, %Store.Project{} = project} <- resolve_project(project) do
      {:ok, Path.join(project.store_path, @filename)}
    end
  end

  def reset do
    with {:ok, path} <- file_path() do
      if File.exists?(path), do: File.rm_rf(path)
      :ok
    end
  end

  @doc """
  Resets the notes file for the given project.

  The project may be provided as a `%Store.Project{}` or as a project name
  binary, which will be resolved via `Store.get_project/1`.
  """
  @spec reset(Store.Project.t() | binary()) :: :ok | {:error, term()}
  def reset(project) do
    with {:ok, path} <- file_path(project) do
      if File.exists?(path), do: File.rm_rf(path)
      :ok
    end
  end

  def write(content) do
    with {:ok, file} <- file_path() do
      File.write(file, content)
    end
  end

  @doc """
  Writes notes content for the given project.

  The project may be provided as a `%Store.Project{}` or as a project name
  binary, which will be resolved via `Store.get_project/1`.
  """
  @spec write(Store.Project.t() | binary(), iodata()) :: :ok | {:error, term()}
  def write(project, content) do
    with {:ok, file} <- file_path(project) do
      File.write(file, content)
    end
  end

  def read do
    with {:ok, file} <- file_path(),
         {:ok, notes} <- File.read(file) do
      case notes do
        "" -> {:error, :no_notes}
        _ -> {:ok, notes}
      end
    else
      {:error, :enoent} -> {:error, :no_notes}
      other -> other
    end
  end

  @doc """
  Reads notes for the given project.

  The project may be provided as a `%Store.Project{}` or as a project name
  binary, which will be resolved via `Store.get_project/1`.
  """
  @spec read(Store.Project.t() | binary()) :: {:ok, String.t()} | {:error, term()}
  def read(project) do
    with {:ok, file} <- file_path(project),
         {:ok, notes} <- File.read(file) do
      case notes do
        "" -> {:error, :no_notes}
        _ -> {:ok, notes}
      end
    else
      {:error, :enoent} -> {:error, :no_notes}
      other -> other
    end
  end

  defp resolve_project(%Store.Project{} = project), do: {:ok, project}
  defp resolve_project(project) when is_binary(project), do: Store.get_project(project)
end
