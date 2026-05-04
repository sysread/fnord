defmodule Cmd.SkillsListTest do
  use Fnord.TestCase, async: false

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  # run/3 returns {:ok, raw_markdown} on success.
  defp list_output(opts \\ %{}) do
    {:ok, output} = Cmd.Skills.run(opts, [:list], [])
    output
  end

  test "includes enabled claude skills in list output" do
    project = mock_project("demo")
    Settings.set_project("demo")
    Settings.ExternalConfigs.set("demo", :claude_skills, true)
    ExternalConfigs.Loader.clear_cache()

    write!(Path.join(project.source_root, ".claude/skills/code-helper/SKILL.md"), """
    ---
    name: code-helper
    description: Helps with code tasks
    ---
    You are a code helper.
    """)

    output = list_output()
    assert String.contains?(output, "code-helper")
    assert String.contains?(output, "Claude Code")
    assert String.contains?(output, "claude:skills")
    assert String.contains?(output, "yes")
  end

  test "includes enabled cursor skills in list output" do
    project = mock_project("demo")
    Settings.set_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_skills, true)
    ExternalConfigs.Loader.clear_cache()

    write!(Path.join(project.source_root, ".cursor/skills/refactor-helper/SKILL.md"), """
    ---
    name: refactor-helper
    description: Assists with refactoring
    ---
    You help refactor code.
    """)

    output = list_output()
    assert String.contains?(output, "refactor-helper")
    assert String.contains?(output, "Cursor")
    assert String.contains?(output, "cursor:skills")
    assert String.contains?(output, "yes")
  end

  test "shows external skill as disabled when source toggle is off" do
    project = mock_project("demo")
    Settings.set_project("demo")
    # claude:skills left at default (false)
    ExternalConfigs.Loader.clear_cache()

    write!(Path.join(project.source_root, ".claude/skills/hidden-skill/SKILL.md"), """
    ---
    name: hidden-skill
    description: A skill with the source disabled
    ---
    Body.
    """)

    output = list_output()
    assert String.contains?(output, "hidden-skill")

    # enabled row should say "no" and not "yes"
    assert String.contains?(output, "| **Enabled** | no |")
    refute String.contains?(output, "yes")
  end

  test "returns no external skills when no project is selected" do
    # No project configured; external_skill_blocks/1 receives nil and returns [].
    output = list_output()
    assert is_binary(output)
    refute String.contains?(output, "Claude Code skill")
    refute String.contains?(output, "Cursor skill")
  end

  test "combines fnord and external skills in list output" do
    project = mock_project("demo")
    Settings.set_project("demo")
    Settings.ExternalConfigs.set("demo", :claude_skills, true)
    ExternalConfigs.Loader.clear_cache()

    # Write a fnord TOML skill in the user dir
    user_dir = Skills.user_skills_dir()
    File.mkdir_p!(user_dir)

    File.write!(Path.join(user_dir, "my-fnord-skill.toml"), """
    name = "my-fnord-skill"
    description = "A fnord TOML skill"
    model = "balanced"
    tools = ["basic"]
    system_prompt = "sp"
    """)

    write!(Path.join(project.source_root, ".claude/skills/my-ext-skill/SKILL.md"), """
    ---
    name: my-ext-skill
    description: An external Claude skill
    ---
    Body.
    """)

    output = list_output()
    assert String.contains?(output, "my-fnord-skill")
    assert String.contains?(output, "my-ext-skill")
  end
end
