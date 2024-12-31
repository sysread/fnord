defmodule Store.Project.Note do
  defstruct [
    :project,
    :store_path,
    :id
  ]

  def new(project), do: new(project, UUID.uuid4())
  def new(project, nil), do: new(project, UUID.uuid4())

  def new(project, id) do
    %__MODULE__{
      project: project,
      store_path: Path.join(project.notes_dir, id),
      id: id
    }
  end

  def exists?(note) do
    File.exists?(note.store_path)
  end

  def write(note, text) do
    # Ensure the note's store path exists.
    note.store_path
    |> File.mkdir_p!()

    # Has the note changed since the last save?
    is_changed? =
      with {:ok, orig} <- read_note(note) do
        orig != text
      else
        _ -> true
      end

    if is_changed? do
      # Write the note's text to the note's store path.
      note.store_path
      |> Path.join("note.md")
      |> File.write!(text)

      # Generate and save embeddings for the note.
      embeddings_json =
        text
        |> AI.Util.generate_embeddings!()
        |> Jason.encode!()

      note.store_path
      |> Path.join("embeddings.json")
      |> File.write!(embeddings_json)
    end
  end

  def read(note) do
    with {:ok, text} <- read_note(note),
         {:ok, embeddings} <- read_embeddings(note) do
      {:ok,
       %{
         id: note.id,
         text: text,
         embeddings: embeddings
       }}
    end
  end

  def read_note(note) do
    note.store_path
    |> Path.join("note.md")
    |> File.read()
  end

  def read_embeddings(note) do
    note.store_path
    |> Path.join("embeddings.json")
    |> File.read()
    |> case do
      {:ok, json} -> Jason.decode(json)
      error -> error
    end
  end
end
