defmodule Cmd.FrobsTest do
  use Fnord.TestCase, async: false

  setup do: set_log_level(:none)
  setup do: {:ok, project: mock_project("frobs_proj")}

  defp frob_paths(name) do
    home = Path.join([Settings.get_user_home(), "fnord", "tools", name])

    %{
      home: home,
      registry: Path.join(home, "registry.json"),
      available: Path.join(home, "available"),
      main: Path.join(home, "main"),
      spec: Path.join(home, "spec.json")
    }
  end

  describe "run/3" do
    test "create prints creation details", %{project: _project} do
      name = "my_frob"

      {stdout, _stderr} =
        capture_all(fn ->
          Cmd.Frobs.run(%{name: name}, [:create], [])
        end)

      assert stdout =~ "> Frob created"
      assert stdout =~ "- Name:     `#{name}`"

      # Verify files exist where expected
      paths = frob_paths(name)
      assert File.exists?(paths.home)
      refute File.exists?(paths.registry)
      assert File.exists?(paths.spec)
      assert File.exists?(paths.main)
    end

    test "check prints valid message after create", %{project: _project} do
      name = "chk_frob"
      # Ensure frob exists
      _ = Frobs.create(name)

      {stdout, _stderr} =
        capture_all(fn ->
          Cmd.Frobs.run(%{name: name}, [:check], [])
        end)

      assert stdout =~ "Frob #{name} appears to be valid!"
    end

    test "list prints registered frobs", %{project: _project} do
      name = "list_frob"
      {:ok, frob} = Frobs.create(name)

      # Make this frob appear in list():
      #  - delete 'available' to bypass dependency checks
      #  - enable it globally in settings
      paths = frob_paths(name)
      if File.exists?(paths.available), do: File.rm!(paths.available)

      Settings.Frobs.enable(:global, name)

      {stdout, _stderr} =
        capture_all(fn ->
          Cmd.Frobs.run(%{}, [:list], [])
        end)

      assert stdout =~ "> Frobs"
      assert stdout =~ "- Name:         #{frob.name}"
    end
  end
end
