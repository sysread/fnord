defmodule Store.StrategyTest do
  use Fnord.TestCase

  alias Store.Strategy

  setup do: set_config(workers: 1, quiet: true)
  setup do: {:ok, project: mock_project("blarg")}

  test "new/0" do
    strategy = Strategy.new()
    assert strategy.store_path == Path.join(Store.store_home(), "strategies/#{strategy.id}")
    refute is_nil(strategy.id)
    refute Strategy.exists?(strategy)
  end

  test "new/1: w/ nil id" do
    strategy = Strategy.new(nil)
    assert strategy.store_path == Path.join(Store.store_home(), "strategies/#{strategy.id}")
    refute is_nil(strategy.id)
    refute Strategy.exists?(strategy)
  end

  test "new/1: w/ id" do
    strategy = Strategy.new("DEADBEEF")
    assert strategy.store_path == Path.join(Store.store_home(), "strategies/#{strategy.id}")
    assert strategy.id == "DEADBEEF"
    refute Strategy.exists?(strategy)
  end

  test "write <=> read" do
    title = "Doing the thing"
    prompt = "Do the thing; verify if thing is done; report doneness of thing"
    questions = ["What is the thing?", "How do you do the thing?"]
    questions_str = questions |> Enum.map(&"- #{&1}") |> Enum.join("\n")

    # ---------------------------------------------------------------------------
    # Create a new strategy that has not yet been saved
    # ---------------------------------------------------------------------------
    strategy = Strategy.new()
    refute Strategy.exists?(strategy)

    # --------------------------------------------------------------------------
    # Save the strategy
    # --------------------------------------------------------------------------
    assert {:ok, ^strategy} = Strategy.write(strategy, title, prompt, questions)

    assert Strategy.exists?(strategy)

    assert File.exists?(strategy.store_path |> Path.join("title.md"))
    assert File.exists?(strategy.store_path |> Path.join("prompt.md"))
    assert File.exists?(strategy.store_path |> Path.join("questions.md"))
    assert File.exists?(strategy.store_path |> Path.join("embeddings.json"))

    assert {:ok, ^title} = Strategy.read_title(strategy)
    assert {:ok, ^prompt} = Strategy.read_prompt(strategy)
    assert {:ok, ^questions_str} = Strategy.read_questions(strategy)
    assert {:ok, [1, 2, 3]} = Strategy.read_embeddings(strategy)

    assert {:ok,
            %{
              title: ^title,
              prompt: ^prompt,
              questions: ^questions_str,
              embeddings: [1, 2, 3]
            }} = Strategy.read(strategy)

    # --------------------------------------------------------------------------
    # Try to save it again with the same parameters, which should fail.
    # --------------------------------------------------------------------------
    id = strategy.id

    assert {:error, {:strategy_exists, ^id}} =
             Strategy.write(strategy, title, prompt, questions)

    # --------------------------------------------------------------------------
    # Try to save it again with different parameters, which should succeed.
    # --------------------------------------------------------------------------
    v2_title = "Doing the thing - but slightly different this time"

    assert {:ok, ^strategy} = Strategy.write(strategy, v2_title, prompt, questions)

    # --------------------------------------------------------------------------
    # Verify that it has been overwritten
    # --------------------------------------------------------------------------
    assert {:ok,
            %{
              title: ^v2_title,
              prompt: ^prompt,
              questions: ^questions_str,
              embeddings: [1, 2, 3]
            }} = Strategy.read(strategy)
  end
end
