defmodule Settings.ExternalConfigsTest do
  use Fnord.TestCase, async: false

  test "defaults are all false when project has no settings" do
    mock_project("demo")
    Settings.set_project("demo")

    assert %{
             cursor_rules: false,
             cursor_skills: false,
             claude_skills: false,
             claude_agents: false
           } = Settings.ExternalConfigs.flags()
  end

  test "claude_agents toggles independently" do
    mock_project("demo")

    assert {:ok, %{claude_agents: true}} =
             Settings.ExternalConfigs.set("demo", :claude_agents, true)

    assert Settings.ExternalConfigs.enabled?("demo", :claude_agents)
    refute Settings.ExternalConfigs.enabled?("demo", :claude_skills)
  end

  test "source_to_string/1 round-trips through source_from_string/1" do
    for source <- Settings.ExternalConfigs.sources() do
      str = Settings.ExternalConfigs.source_to_string(source)
      assert {:ok, ^source} = Settings.ExternalConfigs.source_from_string(str)
    end

    assert {:error, {:invalid_source, "bogus"}} =
             Settings.ExternalConfigs.source_from_string("bogus")
  end

  test "enabled?/2 returns the configured value" do
    mock_project("demo")

    assert {:ok, _} = Settings.ExternalConfigs.set("demo", :cursor_rules, true)
    assert Settings.ExternalConfigs.enabled?("demo", :cursor_rules)
    refute Settings.ExternalConfigs.enabled?("demo", :cursor_skills)
  end

  test "set/3 persists toggles independently" do
    mock_project("demo")

    assert {:ok, %{cursor_rules: true, cursor_skills: false, claude_skills: false}} =
             Settings.ExternalConfigs.set("demo", :cursor_rules, true)

    assert {:ok, %{cursor_rules: true, cursor_skills: false, claude_skills: true}} =
             Settings.ExternalConfigs.set("demo", :claude_skills, true)

    assert {:ok, %{cursor_rules: false, cursor_skills: false, claude_skills: true}} =
             Settings.ExternalConfigs.set("demo", :cursor_rules, false)
  end

  test "set/3 errors for unknown project" do
    assert {:error, :project_not_found} =
             Settings.ExternalConfigs.set("ghost", :cursor_rules, true)
  end
end
