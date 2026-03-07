defmodule AI.Tools.RunSkillTest do
  use Fnord.TestCase, async: false

  defp write_skill!(dir, filename, toml) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, toml)
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
    assert spec.name == "run_skill"
    assert spec.description =~ "alpha"
    assert spec.description =~ "Alpha skill"
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
end
