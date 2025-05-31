defmodule Store.Project.Note do
  @moduledoc """
  This module is deprecated in favor of `Store.Project.Notes`.
  It remains for the purpose of managing legacy notes.
  """

  defstruct [
    :project,
    :store_path,
    :id
  ]

  @type t :: %__MODULE__{}

  def new(project), do: new(project, Uniq.UUID.uuid4())
  def new(project, nil), do: new(project, Uniq.UUID.uuid4())

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
    File.mkdir_p!(note.store_path)

    # Has the note changed since the last save?
    if is_changed?(note, text) do
      # Write the note's text to the note's store path.
      note.store_path
      |> Path.join("note.md")
      |> File.write!(text)

      # Generate and save embeddings for the note.
      with {:ok, embeddings} <- Indexer.impl().get_embeddings(text),
           {:ok, json} <- Jason.encode(embeddings),
           :ok <- note.store_path |> Path.join("embeddings.json") |> File.write(json) do
        {:ok, note}
      end
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
