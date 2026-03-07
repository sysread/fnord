defmodule SkillsTest do
  use Fnord.TestCase, async: false

  defp write_skill!(dir, filename, toml) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, toml)
    path
  end

  test "list_all/0 resolves skills from user + project dirs with user overriding project" do
    # Select a project so Skills will load from the project skills directory.
    project_name = "proj"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}"
    })

    assert :ok = Settings.set_project(project_name)

    # Enablement is not applied in list_all/0, so we don't need to set skills lists.
    user_dir = Skills.user_skills_dir()
    {:ok, project_dir} = Skills.project_skills_dir()

    _user_skill =
      write_skill!(
        user_dir,
        "alpha.toml",
        """
        name = "alpha"
        description = "user definition"
        model = "smart"
        tools = ["basic"]
        system_prompt = "user"
        """
      )

    _project_skill_alpha =
      write_skill!(
        project_dir,
        "alpha.toml",
        """
        name = "alpha"
        description = "project definition"
        model = "fast"
        tools = ["basic"]
        system_prompt = "project"
        """
      )

    _project_skill_beta =
      write_skill!(
        project_dir,
        "beta.toml",
        """
        name = "beta"
        description = "project only"
        model = "balanced"
        tools = ["basic"]
        system_prompt = "project"
        """
      )

    assert {:ok, skills} = Skills.list_all()

    assert Enum.map(skills, & &1.name) == ["alpha", "beta"]

    alpha = Enum.find(skills, &(&1.name == "alpha"))
    assert alpha.effective.source == :user
    assert alpha.effective.skill.description == "user definition"
    assert length(alpha.definitions) == 2

    beta = Enum.find(skills, &(&1.name == "beta"))
    assert beta.effective.source == :project
    assert beta.effective.skill.description == "project only"
    assert length(beta.definitions) == 1
  end

  test "list_enabled/0 filters skills via Settings.Skills effective_enabled" do
    project_name = "proj2"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)

    user_dir = Skills.user_skills_dir()

    _alpha =
      write_skill!(
        user_dir,
        "alpha.toml",
        """
        name = "alpha"
        description = "alpha"
        model = "smart"
        tools = ["basic"]
        system_prompt = "user"
        """
      )

    _beta =
      write_skill!(
        user_dir,
        "beta.toml",
        """
        name = "beta"
        description = "beta"
        model = "smart"
        tools = ["basic"]
        system_prompt = "user"
        """
      )

    assert {:ok, skills} = Skills.list_enabled()
    assert Enum.map(skills, & &1.name) == ["alpha"]
  end

  test "list_all/0 errors on duplicate names within a directory" do
    user_dir = Skills.user_skills_dir()

    _one =
      write_skill!(
        user_dir,
        "a1.toml",
        """
        name = "dup"
        description = "one"
        model = "smart"
        tools = ["basic"]
        system_prompt = "x"
        """
      )

    _two =
      write_skill!(
        user_dir,
        "a2.toml",
        """
        name = "dup"
        description = "two"
        model = "smart"
        tools = ["basic"]
        system_prompt = "y"
        """
      )

    assert {:error, {:duplicate_skill_name, "dup", _paths}} = Skills.list_all()
  end
end
