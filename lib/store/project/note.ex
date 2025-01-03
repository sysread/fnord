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

  def write(note, text, indexer \\ Indexer) do
    if is_valid_format?(text) do
      # Ensure the note's store path exists.
      File.mkdir_p!(note.store_path)

      # Has the note changed since the last save?
      if is_changed?(note, text) do
        # Write the note's text to the note's store path.
        note.store_path
        |> Path.join("note.md")
        |> File.write!(text)

        # Generate and save embeddings for the note.
        with idx <- indexer.new(),
             {:ok, embeddings} <- indexer.get_embeddings(idx, text),
             {:ok, json} <- Jason.encode(embeddings),
             :ok <- note.store_path |> Path.join("embeddings.json") |> File.write(json) do
          {:ok, note}
        end
      end
    else
      {:error, :invalid_format}
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

  # -----------------------------------------------------------------------------
  # Formatting
  # -----------------------------------------------------------------------------
  def is_valid_format?(note_text) do
    note_text
    |> parse_string()
    |> case do
      {:ok, _} -> true
      {:error, :invalid_format, _} -> false
    end
  end

  def parse(note) do
    with {:ok, text} <- read_note(note) do
      parse_string(text)
    end
  end

  def parse_string(input) do
    Store.Project.NoteParser.parse(input)
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp is_changed?(note, text) do
    with {:ok, orig} <- read_note(note) do
      orig != text
    else
      _ -> true
    end
  end
end
