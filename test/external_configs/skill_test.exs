defmodule ExternalConfigs.SkillTest do
  use Fnord.TestCase, async: true

  alias ExternalConfigs.Skill

  defp write_skill!(dir, contents) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, contents)
    path
  end

  test "parses a SKILL.md with frontmatter" do
    {:ok, parent} = tmpdir()
    skill_dir = Path.join(parent, "review")

    write_skill!(skill_dir, """
    ---
    name: review
    description: Review a pull request
    when_to_use: when the user asks to review a PR
    ---
    # How to review

    Steps go here.
    """)

    assert {:ok, skill} = Skill.from_dir(skill_dir, :claude, :project)
    assert skill.name == "review"
    assert skill.description == "Review a pull request"
    assert skill.when_to_use == "when the user asks to review a PR"
    assert skill.flavor == :claude
    assert skill.source == :project
    assert skill.body =~ "# How to review"
  end

  test "falls back to directory name when name is absent" do
    {:ok, parent} = tmpdir()
    skill_dir = Path.join(parent, "MyTool")

    write_skill!(skill_dir, """
    ---
    description: Does things
    ---
    body
    """)

    assert {:ok, skill} = Skill.from_dir(skill_dir, :cursor, :global)
    assert skill.name == "mytool"
    assert skill.flavor == :cursor
    assert skill.source == :global
  end

  test "returns :enoent when SKILL.md is missing" do
    {:ok, parent} = tmpdir()
    skill_dir = Path.join(parent, "empty")
    File.mkdir_p!(skill_dir)

    assert {:error, :enoent} = Skill.from_dir(skill_dir, :claude, :project)
  end

  describe "fnord_skip detection" do
    test "fnord_skip defaults to false for benign skills" do
      {:ok, parent} = tmpdir()
      skill_dir = Path.join(parent, "benign")

      write_skill!(skill_dir, """
      ---
      name: benign
      description: a normal skill
      ---
      Do some work. No reference to anything self-recursive.
      """)

      assert {:ok, skill} = Skill.from_dir(skill_dir, :claude, :project)
      refute skill.fnord_skip
      assert skill.fnord_skip_reason == nil
    end

    test "explicit fnord_skip: true is respected" do
      {:ok, parent} = tmpdir()
      skill_dir = Path.join(parent, "shim")

      write_skill!(skill_dir, """
      ---
      name: shim
      description: delegates to fnord
      fnord_skip: true
      ---
      Body without any obvious recursion hint.
      """)

      assert {:ok, skill} = Skill.from_dir(skill_dir, :claude, :project)
      assert skill.fnord_skip
      assert skill.fnord_skip_reason == :frontmatter
    end

    test "body containing `fnord ask` triggers fallback skip" do
      {:ok, parent} = tmpdir()
      skill_dir = Path.join(parent, "review")

      write_skill!(skill_dir, """
      ---
      name: review
      description: review delegator
      ---
      Run `fnord ask -W . -q "Review <target>"` to delegate.
      """)

      assert {:ok, skill} = Skill.from_dir(skill_dir, :claude, :project)
      assert skill.fnord_skip
      assert skill.fnord_skip_reason == :body_invokes_fnord
    end

    test "body containing `fnord-dev ask` triggers fallback skip" do
      {:ok, parent} = tmpdir()
      skill_dir = Path.join(parent, "review-dev")

      write_skill!(skill_dir, """
      ---
      name: review-dev
      description: dev build delegator
      ---
      Use fnord-dev ask -q "..." for development builds.
      """)

      assert {:ok, skill} = Skill.from_dir(skill_dir, :claude, :project)
      assert skill.fnord_skip
      assert skill.fnord_skip_reason == :body_invokes_fnord
    end

    test "explicit fnord_skip: false overrides body scan" do
      {:ok, parent} = tmpdir()
      skill_dir = Path.join(parent, "documented")

      write_skill!(skill_dir, """
      ---
      name: documented
      description: documentation referencing the command
      fnord_skip: false
      ---
      This skill is unrelated to review but mentions `fnord ask` in passing.
      """)

      assert {:ok, skill} = Skill.from_dir(skill_dir, :claude, :project)
      refute skill.fnord_skip
      assert skill.fnord_skip_reason == nil
    end

    test "body-scan is case-sensitive and word-bounded" do
      {:ok, parent} = tmpdir()
      skill_dir = Path.join(parent, "false-positives")

      write_skill!(skill_dir, """
      ---
      name: false-positives
      description: prose mentioning Fnord
      ---
      Fnord, asking questions, is a project. xfnord asks too. fnordask.
      """)

      assert {:ok, skill} = Skill.from_dir(skill_dir, :claude, :project)
      refute skill.fnord_skip
    end
  end
end
