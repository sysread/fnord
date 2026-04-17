defmodule ExternalConfigs.SkillTest do
  use Fnord.TestCase, async: false

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
end
