defmodule AI.Tools.RunSkillTest do
  use Fnord.TestCase, async: false

  defp write_skill!(dir, filename, toml) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, toml)
    path
  end

  defp write_external_skill!(dir, name, md_content) do
    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)
    path = Path.join(skill_dir, "SKILL.md")
    File.write!(path, md_content)
    path
  end

  test "spec/0 includes available enabled skills" do
    project_name = "proj"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)

    _alpha =
      write_skill!(
        Skills.user_skills_dir(),
        "alpha.toml",
        """
        name = "alpha"
        description = "Alpha skill"
        model = "smart"
        tools = ["basic"]
        system_prompt = "x"
        """
      )

    spec = AI.Tools.RunSkill.spec()
    assert spec.type == "function"
    assert spec.function.name == "run_skill"
    assert spec.function.description =~ "alpha"
    # Full descriptions are in the skill parameter, not the top-level description
    assert spec.function.parameters.properties.skill.description =~ "Alpha skill"
  end

  test "call/1 refuses rw-tagged skill when edit mode is disabled" do
    project_name = "proj2"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)
    Settings.set_edit_mode(false)

    _alpha =
      write_skill!(
        Skills.user_skills_dir(),
        "alpha.toml",
        """
        name = "alpha"
        description = "Alpha skill"
        model = "smart"
        tools = ["basic", "rw"]
        system_prompt = "x"
        """
      )

    assert {:error, {:denied, msg}} =
             AI.Tools.RunSkill.call(%{"skill" => "alpha", "prompt" => "hi"})

    assert msg =~ "--edit"
  end

  test "call/1 refuses disabled skill when not enabled" do
    project_name = "proj3"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)

    _beta =
      write_skill!(
        Skills.user_skills_dir(),
        "beta.toml",
        """
        name = "beta"
        description = "Beta skill"
        model = "smart"
        tools = ["basic"]
        system_prompt = "x"
        """
      )

    assert {:error, :not_found} =
             AI.Tools.RunSkill.call(%{"skill" => "beta", "prompt" => "hi"})
  end

  test "call/1 at max depth still runs but skill cannot recurse (soft-gating)" do
    # Push depth to max so the next call triggers soft-gating
    assert {:ok, _} = Services.SkillDepth.inc_depth()
    assert {:ok, _} = Services.SkillDepth.inc_depth()
    assert {:ok, _} = Services.SkillDepth.inc_depth()

    # At max depth, the skill still runs (soft-gated, not hard-failed).
    # It returns :not_found because "dummy" isn't a real skill, proving
    # execution proceeded rather than being blocked by depth limiting.
    assert {:error, :not_found} =
             AI.Tools.RunSkill.call(%{"skill" => "dummy", "prompt" => "test"})
  end

  test "spec/0 includes enabled external claude skills" do
    project = mock_project("ext_proj")
    Settings.ExternalConfigs.set("ext_proj", :claude_skills, true)
    ExternalConfigs.Loader.clear_cache()

    write_external_skill!(
      Path.join(project.source_root, ".claude/skills"),
      "my-claude-skill",
      """
      ---
      name: my-claude-skill
      description: Does something helpful
      ---
      You are a helpful skill.
      """
    )

    spec = AI.Tools.RunSkill.spec()
    assert spec.function.description =~ "my-claude-skill"
    assert spec.function.parameters.properties.skill.description =~ "Does something helpful"
    assert spec.function.parameters.properties.skill.description =~ "Claude Code skill"
  end

  test "spec/0 includes enabled external cursor skills" do
    project = mock_project("ext_proj2")
    Settings.ExternalConfigs.set("ext_proj2", :cursor_skills, true)
    ExternalConfigs.Loader.clear_cache()

    write_external_skill!(
      Path.join(project.source_root, ".cursor/skills"),
      "my-cursor-skill",
      """
      ---
      name: my-cursor-skill
      description: Refactors things
      ---
      You refactor code.
      """
    )

    spec = AI.Tools.RunSkill.spec()
    assert spec.function.description =~ "my-cursor-skill"
    assert spec.function.parameters.properties.skill.description =~ "Refactors things"
    assert spec.function.parameters.properties.skill.description =~ "Cursor skill"
  end

  test "spec/0 does not include external skills when source toggle is disabled" do
    project = mock_project("ext_proj3")
    # claude_skills left disabled (default)
    ExternalConfigs.Loader.clear_cache()

    write_external_skill!(
      Path.join(project.source_root, ".claude/skills"),
      "hidden-skill",
      """
      ---
      name: hidden-skill
      description: Should not appear
      ---
      Body.
      """
    )

    spec = AI.Tools.RunSkill.spec()
    refute spec.function.description =~ "hidden-skill"
    refute spec.function.parameters.properties.skill.description =~ "Should not appear"
  end

  test "call/1 returns :not_found for unknown external skill name" do
    _project = mock_project("ext_proj4")
    Settings.ExternalConfigs.set("ext_proj4", :claude_skills, true)
    ExternalConfigs.Loader.clear_cache()

    assert {:error, :not_found} =
             AI.Tools.RunSkill.call(%{"skill" => "nonexistent-skill", "prompt" => "hi"})
  end

  test "call/1 returns :not_found for disabled external skill" do
    project = mock_project("ext_proj5")
    # claude_skills left disabled
    ExternalConfigs.Loader.clear_cache()

    write_external_skill!(
      Path.join(project.source_root, ".claude/skills"),
      "disabled-skill",
      """
      ---
      name: disabled-skill
      description: Disabled
      ---
      Body.
      """
    )

    assert {:error, :not_found} =
             AI.Tools.RunSkill.call(%{"skill" => "disabled-skill", "prompt" => "hi"})
  end
end
