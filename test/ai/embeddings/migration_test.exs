defmodule AI.Embeddings.MigrationTest do
  use Fnord.TestCase, async: false

  alias AI.Embeddings.Migration

  setup do
    project = mock_project("embeddings_migration_test")
    {:ok, project: project}
  end

  # Regression: memory embeddings were rewritten via non-atomic File.write/2.
  # A partial-wipe interrupt could leave a truncated file on disk, which
  # would silently skip re-migration (detect_stale_embeddings treats an
  # undecodable file as "no sample") and render the memory unreadable.
  # The migration now routes memory rewrites through Settings.write_atomic!
  # so the on-disk content is always a complete JSON document.
  test "memory wipes produce well-formed JSON with embeddings: null", %{project: project} do
    dir = Path.join(project.store_path, "memory")
    File.mkdir_p!(dir)

    # Stale dim (OpenAI was 3072-d; current local model is 384-d). Any
    # non-384-d sample triggers migration.
    stale = List.duplicate(0.5, 3072)

    a = Path.join(dir, "a.json")
    b = Path.join(dir, "b.json")

    File.write!(a, SafeJson.encode!(%{"title" => "A", "embeddings" => stale}))
    File.write!(b, SafeJson.encode!(%{"title" => "B", "embeddings" => stale}))

    capture_all(fn -> Migration.maybe_migrate(:index) end)

    for path <- [a, b] do
      assert {:ok, contents} = File.read(path)
      assert {:ok, decoded} = SafeJson.decode(contents)
      assert Map.has_key?(decoded, "title")
      assert decoded["embeddings"] == nil
    end
  end

  # No on-disk embeddings of any kind - migration must be a no-op, not
  # a warning-generating run.
  test "no-op when no embeddings exist", %{project: _project} do
    {_stdout, stderr} = capture_all(fn -> assert :ok = Migration.maybe_migrate(:index) end)

    refute stderr =~ "Detected embeddings from a different model"
  end
end
