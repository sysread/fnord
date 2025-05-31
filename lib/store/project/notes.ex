defmodule Store.Project.Notes do
  @filename "notes.md"

  def reset(project_home \\ nil) do
    project_home = Store.get_project_home(project_home)
    new_path = project_home |> Path.join(@filename)
    old_path = project_home |> Path.join("notes")

    if File.exists?(new_path), do: File.rm_rf(new_path)
    if File.exists?(old_path), do: File.rm_rf(old_path)

    :ok
  end

  def write(project_home \\ nil, content) do
    project_home
    |> Store.get_project_home()
    |> Path.join(@filename)
    |> File.write(content)
  end

  def read(project_home \\ nil) do
    project_home
    |> Store.get_project_home()
    |> Path.join(@filename)
    |> File.read()
    |> case do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :no_notes}
      other -> other
    end
  end
end
