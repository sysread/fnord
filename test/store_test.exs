defmodule StoreTest do
  use Fnord.TestCase

  setup do: set_config(workers: 1, quiet: true)
  setup do: {:ok, project: mock_project("blarg")}

  test "store_home/0", %{home_dir: home} do
    fnord_home = Path.join(home, ".fnord")
    assert fnord_home == Store.store_home()
  end

  describe "prompts" do
    test "prompts_dir/0", %{home_dir: home} do
      prompts_dir = Path.join(home, ".fnord/prompts")
      assert prompts_dir == Store.prompts_dir()
    end

    test "list_prompts/0" do
      assert [] == Store.list_prompts()

      {:ok, prompt} =
        Store.Prompt.new()
        |> Store.Prompt.write("Title", "Body", ["Question 1", "Question 2"])

      assert [^prompt] = Store.list_prompts()
    end

    test "search_prompts/2" do
      title = "Semantic Search and High-Level Summaries"
      id = "semantic-search-and-high-level-summaries"

      # Mock the Indexer to return well-known embeddings for the title prompt
      # to ensure it is the first result. All other prompts will return all
      # zeros.
      Mox.stub(MockIndexer, :get_embeddings, fn _, query ->
        if String.contains?(query, title) do
          {:ok, [3, 3, 3]}
        else
          {:ok, [0, 0, 0]}
        end
      end)

      Store.Prompt.install_initial_strategies()

      prompt = Store.Prompt.new(id)
      assert Store.Prompt.exists?(prompt)

      results = Store.search_prompts(title, 5)

      assert 5 == length(results)
      assert [{_, %{id: ^id}} | _] = results
    end
  end
end
