defmodule AI.ModelTest do
  use Fnord.TestCase, async: false

  alias AI.Model

  test "new/3 builds a model struct" do
    m = Model.new("x", 123, :low)
    assert %Model{model: "x", context: 123, reasoning: :low} = m
  end

  test "speed presets return expected models" do
    assert %Model{model: "gpt-5", context: 400_000, reasoning: :minimal} = Model.smart()
    assert %Model{model: "gpt-5.2", context: 400_000, reasoning: :low} = Model.smarter()
    assert %Model{model: "gpt-5-mini", context: 400_000, reasoning: :high} = Model.balanced()
    assert %Model{model: "gpt-4.1-nano", context: 1_000_000, reasoning: :none} = Model.fast()
  end

  test "coding and web_search presets" do
    assert %Model{model: "o4-mini", context: 200_000, reasoning: :high} = Model.coding()

    assert %Model{model: "gpt-4o-mini-search-preview", context: 128_000, reasoning: :none} =
             Model.web_search()
  end

  test "large_context presets" do
    assert %Model{model: "gpt-4.1", context: 1_000_000, reasoning: :none} = Model.large_context()

    assert %Model{model: "gpt-4.1", context: 1_000_000, reasoning: :none} =
             Model.large_context(:smart)

    assert %Model{model: "gpt-4.1-mini", context: 1_000_000, reasoning: :none} =
             Model.large_context(:balanced)

    assert %Model{model: "gpt-4.1-nano", context: 1_000_000, reasoning: :none} =
             Model.large_context(:fast)
  end

  test "OpenAI model helpers respect reasoning argument" do
    assert %Model{model: "gpt-5.2", reasoning: :none} = Model.gpt5(:none)
    assert %Model{model: "gpt-5-mini", reasoning: :high} = Model.gpt5_mini(:high)
    assert %Model{model: "gpt-5-nano", reasoning: :minimal} = Model.gpt5_nano(:minimal)

    assert %Model{model: "o4-mini", reasoning: :low} = Model.o4_mini(:low)
  end

  describe "with_reasoning/2" do
    test "nil reasoning does nothing" do
      m = Model.new("x", 1, :low)
      assert m == Model.with_reasoning(m, nil)
    end

    test "empty string reasoning does nothing" do
      m = Model.new("x", 1, :low)
      assert m == Model.with_reasoning(m, "")
    end

    test "accepts atom reasoning" do
      m = Model.new("x", 1, :low)
      assert %Model{reasoning: :high} = Model.with_reasoning(m, :high)
    end

    test "accepts binary reasoning" do
      m = Model.new("x", 1, :low)
      assert %Model{reasoning: :minimal} = Model.with_reasoning(m, "minimal")
    end

    test "unknown string raises ArgumentError" do
      m = Model.new("x", 1, :low)
      # Choose a string that is extremely unlikely to exist as an atom
      assert_raise ArgumentError, fn ->
        Model.with_reasoning(m, "__definitely_not_a_reasoning_level__")
      end
    end
  end

  describe "with_verbosity/2" do
    test "nil verbosity does nothing" do
      m = Model.new("x", 1, :low)
      assert m == Model.with_verbosity(m, nil)
    end

    test "empty string verbosity does nothing" do
      m = Model.new("x", 1, :low)
      assert m == Model.with_verbosity(m, "")
    end

    test "accepts atom verbosity" do
      m = Model.new("x", 1, :low)
      assert %Model{verbosity: :high} = Model.with_verbosity(m, :high)
    end

    test "accepts binary verbosity" do
      m = Model.new("x", 1, :low)
      assert %Model{verbosity: :low} = Model.with_verbosity(m, "low")
    end

    test "unknown string raises ArgumentError" do
      m = Model.new("x", 1, :low)
      # Choose a string that is extremely unlikely to exist as an atom
      assert_raise ArgumentError, fn ->
        Model.with_verbosity(m, "__definitely_not_a_verbosity_level__")
      end
    end
  end
end
