defmodule AI.Tools.SaveSkillTest do
  use Fnord.TestCase, async: false

  setup do
    # Default to "yes" for confirmations in non-tty tests.
    previous_ui_output = Services.Globals.get_env(:fnord, :ui_output)
    Services.Globals.put_env(:fnord, :ui_output, UI.Output.Mock)

    on_exit(fn ->
      case previous_ui_output do
        nil -> Services.Globals.delete_env(:fnord, :ui_output)
        value -> Services.Globals.put_env(:fnord, :ui_output, value)
      end
    end)

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

    assert {:error, "A user-defined skill named 'alpha' already exists" <> _} =
             AI.Tools.SaveSkill.call(%{
               "scope" => "project",
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
               "scope" => "project",
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

  test "invalid tool tag fails validation early and does not write a file" do
    project_name = "proj3"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)

    # stub confirm again in case it's used
    stub(UI.Output.Mock, :confirm, fn _msg, _default -> true end)

    # Call with an unknown tool tag "typo"
    assert {:error, {:unknown_tool_tag, "typo"}} =
             AI.Tools.SaveSkill.call(%{
               "scope" => "project",
               "name" => "beta",
               "description" => "desc",
               "model" => "smart",
               "tools" => ["typo"],
               "system_prompt" => "sp",
               "response_format" => nil
             })

    # Ensure file was not written
    {:ok, project_dir} = Skills.project_skills_dir()
    path = Path.join(project_dir, "beta.toml")
    refute File.exists?(path)
  end

  test "invalid model preset fails validation early" do
    project_name = "proj4"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)

    stub(UI.Output.Mock, :confirm, fn _msg, _default -> true end)

    assert {:error, {:unknown_model_preset, "nope"}} =
             AI.Tools.SaveSkill.call(%{
               "scope" => "project",
               "name" => "gamma",
               "description" => "desc",
               "model" => "nope",
               "tools" => ["basic"],
               "system_prompt" => "sp",
               "response_format" => nil
             })
  end

  test "invalid response_format fails validation early and does not write a file" do
    project_name = "proj5"

    Settings.set_project_data(Settings.new(), project_name, %{
      "root" => "/tmp/#{project_name}",
      "skills" => ["alpha"]
    })

    assert :ok = Settings.set_project(project_name)

    # stub confirm again in case it's used
    stub(UI.Output.Mock, :confirm, fn _msg, _default -> true end)

    assert {:error, {:invalid_response_format, "nope"}} =
             AI.Tools.SaveSkill.call(%{
               "scope" => "project",
               "name" => "delta",
               "description" => "desc",
               "model" => "smart",
               "tools" => ["basic"],
               "system_prompt" => "sp",
               "response_format" => "nope"
             })

    # Ensure file was not written
    {:ok, project_dir} = Skills.project_skills_dir()
    path = Path.join(project_dir, "delta.toml")
    refute File.exists?(path)
  end

  test "schema-level accepts nil response_format" do
    assert {:ok, coerced} =
             AI.Tools.Params.validate_json_args(AI.Tools.SaveSkill.spec(), %{
               "name" => "a",
               "description" => "d",
               "model" => "smart",
               "tools" => ["basic"],
               "system_prompt" => "sp",
               "response_format" => nil
             })

    assert coerced["response_format"] == nil
  end

  test "writes a new skill into the user skills directory when scope is global" do
    stub(UI.Output.Mock, :confirm, fn _msg, _default -> true end)

    assert {:ok, _msg} =
             AI.Tools.SaveSkill.call(%{
               "scope" => "global",
               "name" => "omega",
               "description" => "desc",
               "model" => "smart",
               "tools" => ["basic"],
               "system_prompt" => "sp",
               "response_format" => nil
             })

    user_dir = Skills.user_skills_dir()
    path = Path.join(user_dir, "omega.toml")
    assert File.exists?(path)
  end

  test "project scope returns friendly error when no project selected" do
    # no project selected
    stub(UI.Output.Mock, :confirm, fn _msg, _default -> true end)

    Services.Globals.delete_env(:fnord, :project)

    assert {:error, "No project selected" <> _} =
             AI.Tools.SaveSkill.call(%{
               "scope" => "project",
               "name" => "theta",
               "description" => "desc",
               "model" => "smart",
               "tools" => ["basic"],
               "system_prompt" => "sp",
               "response_format" => nil
             })
  end
end
