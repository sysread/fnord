defmodule Settings.SkillsTest do
  use Fnord.TestCase, async: false

  describe "effective_enabled/0" do
    test "falls back to global list when no project is selected" do
      Settings.update(Settings.new(), "skills", fn _ -> ["a", "b"] end, [])

      assert Settings.Skills.effective_enabled() == MapSet.new(["a", "b"])
      assert Settings.Skills.enabled?("a")
      refute Settings.Skills.enabled?("nope")
    end

    test "uses project list if project has a skills key" do
      Settings.update(Settings.new(), "skills", fn _ -> ["global"] end, [])

      project_name = "p1"

      Settings.set_project_data(Settings.new(), project_name, %{
        "root" => "/tmp/#{project_name}",
        "skills" => ["proj"]
      })

      assert :ok = Settings.set_project(project_name)

      assert Settings.Skills.effective_enabled() == MapSet.new(["proj"])
      assert Settings.Skills.enabled?("proj")
      refute Settings.Skills.enabled?("global")
    end

    test "uses global list if project does not define a skills key" do
      Settings.update(Settings.new(), "skills", fn _ -> ["global"] end, [])

      project_name = "p2"

      Settings.set_project_data(Settings.new(), project_name, %{
        "root" => "/tmp/#{project_name}"
      })

      assert :ok = Settings.set_project(project_name)

      assert Settings.Skills.effective_enabled() == MapSet.new(["global"])
      assert Settings.Skills.enabled?("global")
    end
  end

  describe "enable/2 and disable/2" do
    test "enable/2 is idempotent and sorts" do
      assert :ok = Settings.Skills.enable(:global, "b")
      assert :ok = Settings.Skills.enable(:global, "a")
      assert :ok = Settings.Skills.enable(:global, "a")

      assert Settings.Skills.list(:global) == ["a", "b"]
    end

    test "disable/2 removes entries" do
      assert :ok = Settings.Skills.enable(:global, "a")
      assert :ok = Settings.Skills.enable(:global, "b")
      assert :ok = Settings.Skills.disable(:global, "a")

      assert Settings.Skills.list(:global) == ["b"]
    end
  end
end
