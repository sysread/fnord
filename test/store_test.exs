defmodule StoreTest do
  use Fnord.TestCase

  setup do: set_config(workers: 1, quiet: true)
  setup do: {:ok, project: mock_project("blarg")}

  test "store_home/0", %{home_dir: home} do
    fnord_home = Path.join(home, ".fnord")
    assert fnord_home == Store.store_home()
  end

  describe "strategies" do
    test "strategies_dir/0", %{home_dir: home} do
      strategies_dir = Path.join(home, ".fnord/strategies")
      assert strategies_dir == Store.strategies_dir()
    end

    test "list_strategies/0" do
      assert [] == Store.list_strategies()

      {:ok, strategy} =
        Store.Strategy.new()
        |> Store.Strategy.write("Title", "Body", ["Question 1", "Question 2"])

      assert [^strategy] = Store.list_strategies()
    end

    test "search_strategies/2" do
      title = "Semantic Search and High-Level Summaries"
      id = "semantic-search-and-high-level-summaries"

      # Mock the Indexer to return well-known embeddings for the title strategy
      # to ensure it is the first result. All other strategies will return all
      # zeros.
      Mox.stub(MockIndexer, :get_embeddings, fn _, query ->
        if String.contains?(query, title) do
          {:ok, [3, 3, 3]}
        else
          {:ok, [0, 0, 0]}
        end
      end)

      Store.Strategy.install_initial_strategies()

      strategy = Store.Strategy.new(id)
      assert Store.Strategy.exists?(strategy)

      results = Store.search_strategies(title, 5)

      assert 5 == length(results)
      assert [{_, %{id: ^id}} | _] = results
    end
  end
end
