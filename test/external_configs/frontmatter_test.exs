defmodule ExternalConfigs.FrontmatterTest do
  use ExUnit.Case, async: true

  alias ExternalConfigs.Frontmatter

  test "parses yaml frontmatter and body" do
    input = """
    ---
    description: a rule
    alwaysApply: true
    globs:
      - "*.ex"
      - "lib/**/*.ex"
    ---
    # Body

    Some instructions.
    """

    assert {:ok, %{frontmatter: fm, body: body}} = Frontmatter.parse(input)
    assert fm["description"] == "a rule"
    assert fm["alwaysApply"] == true
    assert fm["globs"] == ["*.ex", "lib/**/*.ex"]
    assert body =~ "# Body"
    assert body =~ "Some instructions."
  end

  test "returns body-only when no frontmatter" do
    assert {:ok, %{frontmatter: %{}, body: "hello world"}} =
             Frontmatter.parse("hello world")
  end

  test "handles UTF-8 BOM before leading fence" do
    input = <<0xEF, 0xBB, 0xBF>> <> "---\nname: x\n---\nbody\n"
    assert {:ok, %{frontmatter: %{"name" => "x"}, body: body}} = Frontmatter.parse(input)
    assert body =~ "body"
  end

  test "treats unterminated frontmatter as no frontmatter" do
    input = "---\nname: x\nno closer"
    assert {:ok, %{frontmatter: %{}, body: ^input}} = Frontmatter.parse(input)
  end

  test "handles empty frontmatter block" do
    input = """
    ---
    ---
    only body
    """

    assert {:ok, %{frontmatter: %{}, body: body}} = Frontmatter.parse(input)
    assert body =~ "only body"
  end

  test "returns error for invalid yaml inside frontmatter" do
    input = """
    ---
    : not-a-key
    ---
    body
    """

    assert {:error, {:invalid_yaml, _}} = Frontmatter.parse(input)
  end
end
