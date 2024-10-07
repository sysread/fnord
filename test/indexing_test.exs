defmodule IndexingTest do
  use ExUnit.Case

  setup do
    # Create a temp dir for our app to store data. 
    home_dir = mktempdir()

    # Create a temp dir for testing, then initialize as a git repo.
    project_dir = mktempdir()
    System.cmd("git", ["init"], cd: project_dir)

    # Temporarily override the HOME env var to point to our store dir.
    original_home = System.get_env("HOME")
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    {:ok, home_dir: home_dir, store_dir: Path.join(home_dir, ".fnord"), project_dir: project_dir}
  end

  test "run/4", %{store_dir: store_dir, project_dir: project_dir} do
    file_1 = Path.join(project_dir, "file1.txt")
    file_2 = Path.join(project_dir, "file2.txt")

    # Insert a couple of files into the project.
    File.write!(file_1, "file1")
    File.write!(file_2, "file2")

    # Now make file2 git-ignored
    File.write!(Path.join(project_dir, ".gitignore"), "file2.txt")

    # Create an indexer for the project.
    idx = Indexing.new("test_project", project_dir, MockAI)

    # Run the indexing process.
    Indexing.run(idx)

    # Check that the files were indexed.
    assert File.dir?(Path.join(store_dir, "test_project"))
    assert Store.list_projects() == ["test_project"]
    assert Store.list_files(idx.store) == [file_1]
  end

  defp mktempdir() do
    tmp = Path.join(System.tmp_dir!(), "fnord_test_#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end
end

defmodule MockAI do
  defstruct []

  @behaviour AI

  @impl AI
  def new() do
    %MockAI{}
  end

  @impl AI
  def get_embeddings(_ai, _text) do
    {:ok, ["embedding1", "embedding2"]}
  end

  @impl AI
  def get_summary(_ai, _file, _text) do
    {:ok, "summary"}
  end
end
