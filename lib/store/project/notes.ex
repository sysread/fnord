defmodule Store.Project.Notes do
  @filename "notes.json"
  @old_filename "notes.md"

  def sections do
    [
      "Synopsis",
      "User",
      "Layout",
      "Applications & Components",
      "Notes"
    ]
  end

  def file_path do
    with {:ok, project} <- Store.get_project() do
      {:ok, Path.join(project.store_path, @filename)}
    end
  end

  def reset do
    # Remove old and new notes files if they exist
    with {:ok, old_file} <- old_file_path() do
      if File.exists?(old_file), do: File.rm_rf(old_file)
    end

    with {:ok, path} <- file_path() do
      if File.exists?(path), do: File.rm_rf(path)
      :ok
    end
  end

  def write(content) when is_map(content) do
    with {:ok, file} <- file_path(),
         {:ok, json} <- Jason.encode(content) do
      File.write(file, json)
    end
  end

  def write(content) when is_binary(content) do
    with {:ok, file} <- file_path(),
         {:ok, _} <- Jason.decode(content) do
      File.write(file, content)
    end
  end

  def read do
    upgrade_to_json()

    with {:ok, file} <- file_path(),
         {:ok, json} <- File.read(file),
         {:ok, notes} <- Jason.decode(json) do
      {:ok, notes}
    else
      {:error, :enoent} -> {:error, :no_notes}
      other -> other
    end
  end

  def format() do
    with {:ok, notes} <- read() do
      Store.Project.Notes.sections()
      |> Enum.map(fn section ->
        with {:ok, content} <- Map.fetch(notes, section) do
          "# #{section}\n#{content}"
        else
          _ -> "# #{section}\n_No notes available for this section._"
        end
      end)
      |> Enum.join("\n\n")
      |> then(&{:ok, &1})
    end
  end

  # -----------------------------------------------------------------------------
  # Notes were kept as a single markdown file. Now they are a JSON file with
  # sections that are coordinated with the analyzers in AI.Agent.Archivist.
  # -----------------------------------------------------------------------------
  def upgrade_to_json do
    with {:ok, old_file} <- old_file_path(),
         {:ok, old_notes} <- File.read(old_file),
         {:ok, parsed_notes} <- split_markdown(old_notes),
         {:ok, file} <- file_path(),
         {:ok, json} <- Jason.encode(parsed_notes) do
      File.write(file, json)
      File.rm_rf(old_file)
      :ok
    else
      {:error, :no_old_file} -> :ok
      other -> other
    end
  end

  defp old_file_path do
    with {:ok, project} <- Store.get_project() do
      path = Path.join(project.store_path, @old_filename)

      if File.exists?(path) do
        {:ok, path}
      else
        {:error, :no_old_file}
      end
    end
  end

  defp split_markdown(notes) do
    try do
      notes
      |> String.split(~r/^#\s+/m, trim: true)
      |> Enum.filter(&(&1 != ""))
      |> Enum.map(fn chunk ->
        [header, content] = String.split(chunk, ~r/\n+/, parts: 2)
        header = Util.ucfirst(header)
        {header, String.trim(content)}
      end)
      |> Map.new()
      |> then(&{:ok, &1})
    rescue
      _ -> {:error, :invalid_format}
    end
  end
end
