defmodule Store.Project.NotesTest do
  use ExUnit.Case
  use TestUtil

  alias Store.Project.Note

  setup do: set_config(workers: 1, quiet: true)

  setup do
    {:ok, project: mock_project("blarg")}
  end

  test "new: project only", ctx do
    note = Note.new(ctx.project)
    assert note.project == ctx.project
    assert note.store_path == Path.join(ctx.project.notes_dir, note.id)
    refute is_nil(note.id)
    refute Note.exists?(note)
  end

  test "new: project w/ nil id", ctx do
    note = Note.new(ctx.project, nil)
    assert note.project == ctx.project
    assert note.store_path == Path.join(ctx.project.notes_dir, note.id)
    refute is_nil(note.id)
    refute Note.exists?(note)
  end

  test "new: project w/ id", ctx do
    note = Note.new(ctx.project, "DEADBEEF")
    assert note.project == ctx.project
    assert note.store_path == Path.join(ctx.project.notes_dir, note.id)
    assert note.id == "DEADBEEF"
    refute Note.exists?(note)
  end

  test "write <=> read", ctx do
    topic = "{topic foo {fact bar}}"

    note = Note.new(ctx.project, "DEADBEEF")
    refute Note.exists?(note)

    assert {:ok, ^note} = Note.write(note, topic, MockIndexerForNotes)
    assert Note.exists?(note)

    assert {:ok, ^topic} = Note.read_note(note)
    assert {:ok, [1, 2, 3]} = Note.read_embeddings(note)

    assert {:ok,
            %{
              id: "DEADBEEF",
              text: ^topic,
              embeddings: [1, 2, 3]
            }} = Note.read(note)
  end

  test "read: missing note", ctx do
    note = Note.new(ctx.project, "DEADBEEF")
    refute Note.exists?(note)
    assert {:error, :enoent} = Note.read(note)
  end
end

defmodule MockIndexerForNotes do
  defstruct []

  @behaviour Indexer

  @impl Indexer
  def new(), do: %MockIndexerForNotes{}

  @impl Indexer
  def get_embeddings(_idx, _text), do: {:ok, [1, 2, 3]}

  @impl Indexer
  def get_summary(_idx, _file, _text), do: {:ok, "summary"}

  @impl Indexer
  def get_outline(_idx, _file, _text), do: {:ok, "outline"}
end
