defmodule Store.Project.Notes do
  @filename "notes.md"

  @typep project :: nil | binary() | Store.Project.t()
  @typep no_notes :: {:error, :no_notes}

  @spec reset(project()) :: :ok
  def reset(project \\ nil) do
    project = Store.get_project(project)
    new_path = project.store_path |> Path.join(@filename)
    old_path = project.notes_dir

    if File.exists?(new_path) do
      File.rm_rf(new_path)
    end

    if File.exists?(old_path) do
      File.rm_rf(old_path)
    end

    :ok
  end

  @spec write(project(), binary()) :: :ok | no_notes
  def write(project \\ nil, content) do
    project = Store.get_project(project)

    project.store_path
    |> Path.join(@filename)
    |> File.write(content)
    |> case do
      :ok ->
        # UI.info("Upgrading notes to new format")
        # File.rm_rf!(project.notes_dir)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec read(project()) :: {:ok, binary()} | no_notes
  def read(project \\ nil) do
    project
    |> Store.get_project()
    |> read_notes()
  end

  defp read_notes(project) do
    project
    |> read_new_notes()
    |> case do
      {:ok, notes} -> {:ok, notes}
      {:error, :no_notes} -> project |> read_old_notes()
    end
    |> case do
      {:ok, notes} -> {:ok, notes |> String.trim()}
      other -> other
    end
  end

  defp read_new_notes(%{store_path: store_path}) do
    path = store_path |> Path.join(@filename)

    if File.exists?(path) do
      File.read(path)
    else
      {:error, :no_notes}
    end
  end

  defp read_old_notes(project) do
    project.notes_dir
    |> File.ls()
    |> case do
      {:ok, dirs} ->
        dirs
        |> Enum.sort()
        |> Enum.map(&Store.Project.Note.new(project, &1))
        |> Enum.map(&Store.Project.Note.read_note/1)
        |> Enum.filter(fn
          {:ok, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:ok, note} -> note end)
        |> Enum.join("\n\n")
        |> then(fn notes ->
          {:ok,
           """
           !!! These research notes are in an old, legacy format.
           !!! They must be replaced with the new format.

           #{notes}
           """}
        end)

      _ ->
        {:error, :no_notes}
    end
  end
end
