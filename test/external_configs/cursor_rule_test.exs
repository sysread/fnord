defmodule ExternalConfigs.CursorRuleTest do
  use Fnord.TestCase, async: false

  alias ExternalConfigs.CursorRule

  defp write_rule!(dir, name, contents) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  defp load_rule_with_globs!(globs) do
    {:ok, dir} = tmpdir()

    path =
      write_rule!(dir, "r.mdc", """
      ---
      description: d
      globs: #{inspect(globs)}
      ---
      body
      """)

    {:ok, rule} = CursorRule.from_file(path, :project)
    rule
  end

  test "classifies alwaysApply rules as :always" do
    {:ok, dir} = tmpdir()

    path =
      write_rule!(dir, "always.mdc", """
      ---
      description: always applied
      alwaysApply: true
      ---
      Body text.
      """)

    assert {:ok, rule} = CursorRule.from_file(path, :project)
    assert rule.name == "always"
    assert rule.mode == :always
    assert rule.always_apply == true
    assert rule.description == "always applied"
    assert rule.body == "Body text."
    assert rule.source == :project
  end

  test "classifies rules with globs as :auto_attached" do
    {:ok, dir} = tmpdir()

    path =
      write_rule!(dir, "ts.mdc", """
      ---
      description: typescript
      globs: "*.ts, app/**/*.tsx"
      ---
      Body.
      """)

    assert {:ok, rule} = CursorRule.from_file(path, :project)
    assert rule.mode == :auto_attached
    assert rule.globs == ["*.ts", "app/**/*.tsx"]
  end

  test "accepts globs as a YAML list" do
    {:ok, dir} = tmpdir()

    path =
      write_rule!(dir, "ls.mdc", """
      ---
      description: test
      globs:
        - "*.ex"
        - "lib/**/*.ex"
      ---
      Body.
      """)

    assert {:ok, rule} = CursorRule.from_file(path, :project)
    assert rule.globs == ["*.ex", "lib/**/*.ex"]
  end

  test "classifies description-only rules as :agent_requested" do
    {:ok, dir} = tmpdir()

    path =
      write_rule!(dir, "desc.mdc", """
      ---
      description: only a description
      ---
      Body.
      """)

    assert {:ok, rule} = CursorRule.from_file(path, :project)
    assert rule.mode == :agent_requested
  end

  test "classifies rules with no fields as :manual" do
    {:ok, dir} = tmpdir()

    path =
      write_rule!(dir, "man.mdc", """
      ---
      ---
      Body.
      """)

    assert {:ok, rule} = CursorRule.from_file(path, :project)
    assert rule.mode == :manual
  end

  test "from_legacy_file produces an :always / :legacy rule" do
    {:ok, dir} = tmpdir()
    path = Path.join(dir, ".cursorrules")
    File.write!(path, "legacy rule text")

    assert {:ok, rule} = CursorRule.from_legacy_file(path)
    assert rule.name == ".cursorrules"
    assert rule.mode == :always
    assert rule.source == :legacy
    assert rule.body == "legacy rule text"
  end

  describe "matches_path?/2" do
    test "single-star glob matches only top-level files" do
      rule = load_rule_with_globs!(["*.ex"])

      assert CursorRule.matches_path?(rule, "foo.ex")
      refute CursorRule.matches_path?(rule, "lib/foo.ex")
    end

    test "double-star matches across directories" do
      rule = load_rule_with_globs!(["lib/**/*.ex"])

      assert CursorRule.matches_path?(rule, "lib/foo.ex")
      assert CursorRule.matches_path?(rule, "lib/deep/nested/file.ex")
      refute CursorRule.matches_path?(rule, "README.md")
    end

    test "multiple globs match if any match" do
      rule = load_rule_with_globs!(["*.md", "app/**/*.tsx"])

      assert CursorRule.matches_path?(rule, "README.md")
      assert CursorRule.matches_path?(rule, "app/component.tsx")
      refute CursorRule.matches_path?(rule, "lib/foo.ex")
    end

    test "rule with no globs never matches" do
      {:ok, dir} = tmpdir()

      path =
        write_rule!(dir, "m.mdc", """
        ---
        description: only desc
        ---
        body
        """)

      {:ok, rule} = CursorRule.from_file(path, :project)
      refute CursorRule.matches_path?(rule, "anything")
    end
  end
end
