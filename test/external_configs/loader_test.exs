defmodule ExternalConfigs.LoaderTest do
  use Fnord.TestCase, async: false

  alias ExternalConfigs.Loader

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp rule_contents(opts) do
    desc = Keyword.get(opts, :description, "r")
    body = Keyword.get(opts, :body, "body")

    extras =
      opts
      |> Keyword.take([:always_apply, :globs])
      |> Enum.map(fn
        {:always_apply, v} -> "alwaysApply: #{v}"
        {:globs, v} -> "globs: #{inspect(v)}"
      end)
      |> Enum.join("\n")

    """
    ---
    description: #{desc}
    #{extras}
    ---
    #{body}
    """
  end

  defp skill_contents(opts) do
    name = Keyword.get(opts, :name, "s")
    desc = Keyword.get(opts, :description, "d")

    """
    ---
    name: #{name}
    description: #{desc}
    ---
    body
    """
  end

  test "returns empty lists when no external configs exist" do
    project = mock_project("demo")

    loaded = Loader.load(project)
    assert loaded.cursor_rules == []
    assert loaded.cursor_skills == []
    assert loaded.claude_skills == []
    assert loaded.claude_agents == []
  end

  test "respects settings toggles (all default to false)" do
    project = mock_project("demo")

    write!(
      Path.join(project.source_root, ".cursor/rules/x.mdc"),
      rule_contents(always_apply: true)
    )

    loaded = Loader.load(project)
    assert loaded.cursor_rules == []
  end

  test "loads project cursor rules when enabled" do
    project = mock_project("demo")

    Settings.ExternalConfigs.set("demo", :cursor_rules, true)

    write!(
      Path.join(project.source_root, ".cursor/rules/x.mdc"),
      rule_contents(always_apply: true)
    )

    loaded = Loader.load(project)
    assert [rule] = loaded.cursor_rules
    assert rule.name == "x"
    assert rule.source == :project
    assert rule.mode == :always
  end

  test "project cursor rules override global ones with the same name", %{home_dir: home} do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_rules, true)

    global_dir = Path.join(home, ".cursor/rules")

    write!(
      Path.join(global_dir, "dup.mdc"),
      rule_contents(description: "from-global", always_apply: true)
    )

    write!(
      Path.join(project.source_root, ".cursor/rules/dup.mdc"),
      rule_contents(description: "from-project", always_apply: true)
    )

    loaded = Loader.load(project)
    assert [rule] = loaded.cursor_rules
    assert rule.description == "from-project"
    assert rule.source == :project
  end

  test "includes legacy .cursorrules when present" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_rules, true)

    write!(Path.join(project.source_root, ".cursorrules"), "legacy content")

    loaded = Loader.load(project)
    assert Enum.any?(loaded.cursor_rules, &(&1.source == :legacy))
  end

  test "loads claude skills when enabled" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :claude_skills, true)

    write!(
      Path.join(project.source_root, ".claude/skills/review/SKILL.md"),
      skill_contents(name: "review", description: "review PRs")
    )

    loaded = Loader.load(project)
    assert [%{name: "review", flavor: :claude, source: :project}] = loaded.claude_skills
  end

  test "loads cursor skills when enabled" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_skills, true)

    write!(
      Path.join(project.source_root, ".cursor/skills/hello/SKILL.md"),
      skill_contents(name: "hello", description: "says hi")
    )

    loaded = Loader.load(project)
    assert [%{name: "hello", flavor: :cursor, source: :project}] = loaded.cursor_skills
  end

  test "loads claude agents when enabled" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :claude_agents, true)

    write!(
      Path.join(project.source_root, ".claude/agents/review-pedantic.md"),
      """
      ---
      name: review-pedantic
      description: Mechanical-correctness specialist.
      tools: Bash, Read, Grep
      ---
      body
      """
    )

    loaded = Loader.load(project)

    assert [%ExternalConfigs.Agent{name: "review-pedantic", source: :project}] =
             loaded.claude_agents
  end

  test "dedup_cross_flavor/2 drops cursor skills whose dir resolves to the same real path as a claude skill" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_skills, true)
    Settings.ExternalConfigs.set("demo", :claude_skills, true)

    # Write the skill under cursor
    write!(
      Path.join(project.source_root, ".cursor/skills/shared-skill/SKILL.md"),
      skill_contents(name: "shared-skill", description: "shared")
    )

    # Symlink the individual skill directory from .claude/skills into .cursor/skills
    claude_skills_dir = Path.join(project.source_root, ".claude/skills")
    File.mkdir_p!(claude_skills_dir)

    :ok =
      File.ln_s(
        Path.join(project.source_root, ".cursor/skills/shared-skill"),
        Path.join(claude_skills_dir, "shared-skill")
      )

    ExternalConfigs.Loader.clear_cache()
    loaded = Loader.load(project)

    # Claude flavor is kept; cursor flavor is dropped (same real path)
    assert [%{name: "shared-skill", flavor: :claude}] = loaded.claude_skills
    assert loaded.cursor_skills == []
  end

  test "dedup_cross_flavor/2 drops cursor skills when entire .claude/skills is a symlink to .cursor/skills" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_skills, true)
    Settings.ExternalConfigs.set("demo", :claude_skills, true)

    cursor_skills_dir = Path.join(project.source_root, ".cursor/skills")

    write!(
      Path.join(cursor_skills_dir, "my-skill/SKILL.md"),
      skill_contents(name: "my-skill", description: "d")
    )

    # .claude/ must exist before symlinking .claude/skills into it
    File.mkdir_p!(Path.join(project.source_root, ".claude"))
    :ok = File.ln_s(cursor_skills_dir, Path.join(project.source_root, ".claude/skills"))

    ExternalConfigs.Loader.clear_cache()
    loaded = Loader.load(project)

    assert [%{name: "my-skill", flavor: :claude}] = loaded.claude_skills
    assert loaded.cursor_skills == []
  end

  test "dedup_cross_flavor/2 drops cursor skill with same name as a claude skill at a distinct path" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_skills, true)
    Settings.ExternalConfigs.set("demo", :claude_skills, true)

    write!(
      Path.join(project.source_root, ".cursor/skills/shared-name/SKILL.md"),
      skill_contents(name: "shared-name", description: "cursor version")
    )

    write!(
      Path.join(project.source_root, ".claude/skills/shared-name/SKILL.md"),
      skill_contents(name: "shared-name", description: "claude version")
    )

    ExternalConfigs.Loader.clear_cache()
    loaded = Loader.load(project)

    assert [%{name: "shared-name", flavor: :claude, description: "claude version"}] =
             loaded.claude_skills

    assert loaded.cursor_skills == []
  end

  test "dedup_cross_flavor/2 keeps cursor skills with distinct real paths" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_skills, true)
    Settings.ExternalConfigs.set("demo", :claude_skills, true)

    write!(
      Path.join(project.source_root, ".cursor/skills/cursor-only/SKILL.md"),
      skill_contents(name: "cursor-only", description: "only in cursor")
    )

    write!(
      Path.join(project.source_root, ".claude/skills/claude-only/SKILL.md"),
      skill_contents(name: "claude-only", description: "only in claude")
    )

    ExternalConfigs.Loader.clear_cache()
    loaded = Loader.load(project)

    assert [%{name: "cursor-only", flavor: :cursor}] = loaded.cursor_skills
    assert [%{name: "claude-only", flavor: :claude}] = loaded.claude_skills
  end

  test "has_any_on_disk?/2 detects claude agents" do
    project = mock_project("demo")
    refute ExternalConfigs.Loader.has_any_on_disk?(project, :claude_agents)

    write!(
      Path.join(project.source_root, ".claude/agents/foo.md"),
      """
      ---
      name: foo
      description: d
      ---
      body
      """
    )

    assert ExternalConfigs.Loader.has_any_on_disk?(project, :claude_agents)
  end
end
