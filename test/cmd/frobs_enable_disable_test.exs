defmodule Cmd.FrobsEnableDisableTest do
  use Fnord.TestCase, async: false

  setup do: set_log_level(:none)

  defp frob_paths(name) do
    home = Path.join([Settings.get_user_home(), "fnord", "tools", name])

    %{
      home: home,
      available: Path.join(home, "available"),
      main: Path.join(home, "main"),
      spec: Path.join(home, "spec.json")
    }
  end

  test "enable globally toggles settings and reports scope" do
    name = "cli_frob_global"
    {:ok, _frob} = Frobs.create(name)

    # Ensure availability check does not block list (not strictly needed here)
    paths = frob_paths(name)
    if File.exists?(paths.available), do: File.rm!(paths.available)

    {stdout, _stderr} =
      capture_all(fn -> Cmd.Frobs.run(%{name: name, global: true}, [:enable], []) end)

    assert stdout =~ "enabled in global scope"
    assert Settings.Frobs.enabled?(name)

    # Now disable globally
    {stdout2, _stderr2} =
      capture_all(fn -> Cmd.Frobs.run(%{name: name, global: true}, [:disable], []) end)

    assert stdout2 =~ "disabled in global scope"
    refute Settings.Frobs.enabled?(name)
  end

  test "enable for selected project and then disable" do
    project = mock_project("proj_enable")
    name = "cli_frob_project"
    {:ok, _frob} = Frobs.create(name)

    paths = frob_paths(name)
    if File.exists?(paths.available), do: File.rm!(paths.available)

    # Enable without --global or --project uses selected project
    {stdout, _stderr} = capture_all(fn -> Cmd.Frobs.run(%{name: name}, [:enable], []) end)
    assert stdout =~ "enabled in project (selected) scope"

    # Effective enablement should include the frob now
    assert Settings.Frobs.enabled?(name)
    assert name in Settings.Frobs.list(:project)

    # Disable now
    {stdout2, _stderr2} = capture_all(fn -> Cmd.Frobs.run(%{name: name}, [:disable], []) end)
    assert stdout2 =~ "disabled in project (selected) scope"
    refute Settings.Frobs.enabled?(name)
    refute name in Settings.Frobs.list(:project)

    # Keep dialyzer quiet about unused variable
    assert is_map(project)
  end

  test "enable for explicit project via --project <name>" do
    name = "cli_frob_explicit_project"
    {:ok, _frob} = Frobs.create(name)

    paths = frob_paths(name)
    if File.exists?(paths.available), do: File.rm!(paths.available)

    # Enable for a project without selecting it
    {stdout, _stderr} =
      capture_all(fn -> Cmd.Frobs.run(%{name: name, project: "acme"}, [:enable], []) end)

    assert stdout =~ "enabled in project: acme scope"

    # Verify project data was updated
    settings = Settings.new()
    pdata = Settings.get_project_data(settings, "acme") || %{}
    frobs = Map.get(pdata, "frobs", [])
    assert name in frobs

    # Not enabled in effective set until 'acme' is selected
    refute Settings.Frobs.enabled?(name)

    # Select the project and confirm effective enablement
    # Select 'acme' as the current project without overwriting its settings
    set_config(:project, "acme")
    assert Settings.Frobs.enabled?(name)
  end
end
