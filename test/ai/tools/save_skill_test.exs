defmodule AI.Tools.SaveSkillTest do
  use Fnord.TestCase, async: false

  setup do
    # Default to "yes" for confirmations in non-tty tests.
    Services.Globals.put_env(:fnord, :ui_output, UI.Output.Mock)
    stub(UI.Output.Mock, :confirm, fn _msg, _default -> true end)
    :ok
  end

  defp write_user_skill!(name) do
    dir = Skills.user_skills_dir()
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "#{name}.toml"),
      """
      name = "#{name}"
      description = "user"
      model = "smart"
      tools = ["basic"]
      system_prompt = "x"
      """
    )
  end

  test "refuses to save a project skill that collides with a user-defined skill" do
    project_name = "proj"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)

    write_user_skill!("alpha")

    assert {:error, {:skill_exists_in_user_dir, "alpha"}} =
             AI.Tools.SaveSkill.call(%{
               "name" => "alpha",
               "description" => "d",
               "model" => "smart",
               "tools" => ["basic"],
               "system_prompt" => "sp",
               "response_format" => nil
             })
  end

  test "writes a new skill into the project skills directory" do
    project_name = "proj2"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)

    assert {:ok, msg} =
             AI.Tools.SaveSkill.call(%{
               "name" => "alpha",
               "description" => "d",
               "model" => "smart",
               "tools" => ["basic"],
               "system_prompt" => "sp",
               "response_format" => %{"type" => "text"}
             })

    assert msg =~ "Saved skill alpha"

    {:ok, project_dir} = Skills.project_skills_dir()
    path = Path.join(project_dir, "alpha.toml")
    assert File.exists?(path)

    assert {:ok, %{"name" => "alpha"}} = Fnord.Toml.decode_file(path)
  end
end
