defmodule SearchTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  setup do
    # Create a temporary home directory for the application's store
    home_dir = mktempdir()
    # Create a temporary project directory and initialize it as a git repo
    project_dir = mktempdir()

    System.cmd("git", ["init"],
      cd: project_dir,
      env: [
        {"GIT_TRACE", "0"},
        {"GIT_CURL_VERBOSE", "0"},
        {"GIT_DEBUG", "0"}
      ]
    )

    # Temporarily override the HOME environment variable
    original_home = System.get_env("HOME")
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    {:ok, home_dir: home_dir, project_dir: project_dir}
  end

  test "search returns files ranked by similarity to query", %{
    project_dir: project_dir
  } do
    # Create sample files with known content
    file1 = Path.join(project_dir, "file1.txt")
    File.write!(file1, "file1")

    file2 = Path.join(project_dir, "file2.txt")
    File.write!(file2, "file2")

    file3 = Path.join(project_dir, "file3.txt")
    File.write!(file3, "other content")

    # Index the files using the Indexer with MockAIForSearch
    idx =
      Indexer.new(
        %{
          project: "test_project",
          directory: project_dir,
          quiet: true
        },
        MockAIForSearch
      )

    Indexer.run(idx)

    # Define search options
    search_opts = %{
      project: "test_project",
      query: "file1",
      limit: 1,
      detail: false,
      concurrency: 1
    }

    # Capture the output of the Search.run/2 function
    output =
      capture_io(fn ->
        Search.run(search_opts, MockAIForSearch)
      end)

    # Split the output into lines
    results = output |> String.split("\n", trim: true)

    # Assert that file1.txt is the first result
    assert List.first(results) == file1

    # Assert that file2.txt and file3.txt are not in the results (since they have lower similarity)
    assert Enum.member?(results, file2) == false
    assert Enum.member?(results, file3) == false
  end

  test "cosine_similarity/2 computes correct similarity", _context do
    vec1 = [1.0, 0.0, 0.0]
    vec2 = [0.0, 1.0, 0.0]
    vec3 = [1.0, 0.0, 0.0]

    # Cosine similarity between orthogonal vectors should be 0
    assert Search.cosine_similarity(vec1, vec2) == 0.0

    # Cosine similarity between identical vectors should be 1
    assert Search.cosine_similarity(vec1, vec3) == 1.0

    # Cosine similarity between vector and itself
    similarity = Search.cosine_similarity(vec1, vec1)
    assert similarity == 1.0

    # Cosine similarity between arbitrary vectors
    vec4 = [1.0, 2.0, 3.0]
    vec5 = [4.0, 5.0, 6.0]
    similarity = Search.cosine_similarity(vec4, vec5)
    # Compute expected value
    dot_product = Enum.zip(vec4, vec5) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec4, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec5, 0.0, fn x, acc -> acc + x * x end))
    expected_similarity = dot_product / (magnitude1 * magnitude2)
    assert_in_delta similarity, expected_similarity, 1.0e-5
  end

  defp mktempdir() do
    tmp = Path.join(System.tmp_dir!(), "fnord_test_#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end
end

defmodule MockAIForSearch do
  defstruct []

  @behaviour AI

  @impl AI
  def new() do
    %MockAIForSearch{}
  end

  @impl AI
  def get_embeddings(_ai, text) do
    embedding =
      cond do
        String.contains?(text, "file1") ->
          Enum.concat([1.0], List.duplicate(0.0, 3071))

        String.contains?(text, "file2") ->
          Enum.concat([0.0, 1.0], List.duplicate(0.0, 3071))

        String.contains?(text, "other content") ->
          Enum.concat([0.0, 0.0, 1.0], List.duplicate(0.0, 3070))

        true ->
          List.duplicate(0.0, 3072)
      end

    {:ok, [embedding]}
  end

  @impl AI
  def get_summary(_ai, _file, _text) do
    {:ok, "summary"}
  end
end
