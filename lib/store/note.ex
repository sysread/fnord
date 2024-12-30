defmodule Store.Note do
  defstruct [
    :project,
    :store_path,
    :id
  ]

  @store_dir "notes"

  # ----------------------------------------------------------------------------
  # Instance functions
  # ----------------------------------------------------------------------------
  def new(project), do: new(project, UUID.uuid4())
  def new(project, nil), do: new(project, UUID.uuid4())

  def new(project, id) do
    %__MODULE__{
      project: project,
      store_path: build_store_path(project, id),
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
        |> generate_embeddings!()
        |> Jason.encode!()

      note.store_path
      |> Path.join("embeddings.json")
      |> File.write!(embeddings_json)
    end
  end

  def read(note) do
    with {:ok, text} <- read_note(note),
         {:ok, embeddings} <- read_embeddings(note) do
      {:ok, %{text: text, embeddings: embeddings}}
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

  # ----------------------------------------------------------------------------
  # Common functions
  # ----------------------------------------------------------------------------
  def list_notes(project) do
    project.store_path
    |> Path.join(@store_dir)
    |> File.ls()
    |> case do
      {:ok, dirs} ->
        dirs
        |> Enum.sort()
        |> Enum.map(&new(project, &1))

      _ ->
        []
    end
  end

  def search(project, query, max_results \\ 20) do
    needle = generate_embeddings!(query)

    list_notes(project)
    |> Enum.reduce([], fn note, acc ->
      with {:ok, embeddings} <- read_embeddings(note) do
        score = AI.Util.cosine_similarity(needle, embeddings)
        [{score, note} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> a >= b end)
    |> Enum.take(max_results)
  end

  # ----------------------------------------------------------------------------
  # Private functions
  # ----------------------------------------------------------------------------
  defp build_store_path(project, id) do
    project.store_path
    |> Path.join(@store_dir)
    |> Path.join(id)
  end

  defp generate_embeddings!(text) do
    AI.new()
    |> AI.get_embeddings(text)
    |> case do
      {:ok, embeddings} -> Enum.zip_with(embeddings, &Enum.max/1)
      {:error, reason} -> raise "Failed to generate embeddings: #{inspect(reason)}"
    end
  end
end
