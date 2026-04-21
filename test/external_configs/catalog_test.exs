defmodule ExternalConfigs.CatalogTest do
  use Fnord.TestCase, async: false

  alias ExternalConfigs.Catalog

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  test "returns [] when no project is selected" do
    # No project configured yet
    assert Catalog.build_messages() == []
  end

  test "system_messages/0 wraps each build_messages/0 entry as a system msg" do
    project = mock_project("demo")
    Settings.set_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_rules, true)

    write!(Path.join(project.source_root, ".cursor/rules/style.mdc"), """
    ---
    description: style
    alwaysApply: true
    ---
    Always follow these guidelines.
    """)

    strings = Catalog.build_messages()
    wrapped = Catalog.system_messages()

    assert length(wrapped) == length(strings)

    # Each entry carries the string content in its :content field under
    # a system-role message.
    Enum.zip(strings, wrapped)
    |> Enum.each(fn {s, msg} ->
      assert is_map(msg)
      assert Map.get(msg, :content) == s
    end)
  end

  test "system_messages/0 returns [] with no project selected" do
    assert Catalog.system_messages() == []
  end

  test "returns [] when all toggles are disabled and no fnord skills" do
    project = mock_project("demo")
    assert Catalog.build_messages(project) == []
  end

  test "emits catalog listing cursor rules (non-always modes)" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_rules, true)

    write!(Path.join(project.source_root, ".cursor/rules/typescript.mdc"), """
    ---
    description: typescript rules
    globs: "*.ts"
    ---
    body
    """)

    write!(Path.join(project.source_root, ".cursor/rules/testing.mdc"), """
    ---
    description: how to test
    ---
    body
    """)

    messages = Catalog.build_messages(project)

    catalog_msg = Enum.find(messages, &String.contains?(&1, "Cursor rules"))
    assert catalog_msg
    assert catalog_msg =~ "typescript"
    assert catalog_msg =~ "auto-attached"
    assert catalog_msg =~ "testing"
    assert catalog_msg =~ "agent-requested"
  end

  test "emits separate message per always-apply rule body" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_rules, true)

    write!(Path.join(project.source_root, ".cursor/rules/style.mdc"), """
    ---
    description: style
    alwaysApply: true
    ---
    Always follow these guidelines.
    """)

    messages = Catalog.build_messages(project)

    assert Enum.any?(messages, fn m ->
             String.contains?(m, "always-applied") and
               String.contains?(m, "Always follow these guidelines.")
           end)
  end

  test "emits skills catalog with cursor + claude sections when enabled" do
    project = mock_project("demo")
    Settings.ExternalConfigs.set("demo", :cursor_skills, true)
    Settings.ExternalConfigs.set("demo", :claude_skills, true)

    write!(Path.join(project.source_root, ".cursor/skills/hello/SKILL.md"), """
    ---
    name: hello
    description: says hi
    ---
    body
    """)

    write!(Path.join(project.source_root, ".claude/skills/review/SKILL.md"), """
    ---
    name: review
    description: review a PR
    ---
    body
    """)

    messages = Catalog.build_messages(project)

    catalog =
      Enum.find(messages, fn m ->
        String.contains?(m, "Cursor skills") or String.contains?(m, "Claude Code skills")
      end)

    assert catalog
    assert catalog =~ "Cursor skills"
    assert catalog =~ "Claude Code skills"
    # External skill entries include the SKILL.md path so the LLM can
    # read the body with file_contents_tool.
    assert catalog =~ ~r{- hello \(.+hello/SKILL\.md\): says hi}
    assert catalog =~ ~r{- review \(.+review/SKILL\.md\): review a PR}
  end

  describe "claude agents" do
    defp write_agent!(project, name, tools) do
      path = Path.join(project.source_root, ".claude/agents/#{name}.md")
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      ---
      name: #{name}
      description: agent #{name}
      tools: #{tools}
      ---
      body for #{name}
      """)
    end

    test "lists non-edit agents in research mode" do
      project = mock_project("demo")
      Settings.ExternalConfigs.set("demo", :claude_agents, true)
      Settings.set_edit_mode(false)
      on_exit(fn -> Settings.set_edit_mode(false) end)

      write_agent!(project, "review-pedantic", "Bash, Read, Grep")

      messages = Catalog.build_messages(project)
      catalog = Enum.find(messages, &String.contains?(&1, "Claude Code subagents"))

      assert catalog
      assert catalog =~ ~r{- review-pedantic \(.+review-pedantic\.md\): agent review-pedantic}
    end

    test "hides agents that require edit mode and emits a count note" do
      project = mock_project("demo")
      Settings.ExternalConfigs.set("demo", :claude_agents, true)
      Settings.set_edit_mode(false)
      on_exit(fn -> Settings.set_edit_mode(false) end)

      write_agent!(project, "review-pedantic", "Bash, Read, Grep")
      write_agent!(project, "coder", "Bash, Read, Write, Edit")
      write_agent!(project, "refactorer", "Read, Edit")

      messages = Catalog.build_messages(project)
      catalog = Enum.find(messages, &String.contains?(&1, "Claude Code subagents"))

      assert catalog =~ "review-pedantic"
      refute catalog =~ "- coder ("
      refute catalog =~ "- refactorer ("
      assert catalog =~ "2 additional Claude Code agents require edit mode"
      assert catalog =~ "rerun with --edit"
    end

    test "lists edit-requiring agents when edit mode is on" do
      project = mock_project("demo")
      Settings.ExternalConfigs.set("demo", :claude_agents, true)
      Settings.set_edit_mode(true)
      on_exit(fn -> Settings.set_edit_mode(false) end)

      write_agent!(project, "coder", "Bash, Read, Write, Edit")

      messages = Catalog.build_messages(project)
      catalog = Enum.find(messages, &String.contains?(&1, "Claude Code subagents"))

      assert catalog =~ "coder"
      refute catalog =~ "require edit mode"
    end

    # Regression: when EVERY Claude agent requires edit mode (and there are no
    # other skills/rules), the catch-all skills_catalog_message/5 clause
    # previously swallowed the entire section with `nil`, hiding the
    # "N agents require edit mode" note meant to surface exactly this case.
    test "emits hidden-only note when all agents require edit mode" do
      project = mock_project("demo")
      Settings.ExternalConfigs.set("demo", :claude_agents, true)
      Settings.set_edit_mode(false)
      on_exit(fn -> Settings.set_edit_mode(false) end)

      write_agent!(project, "coder", "Bash, Read, Write, Edit")
      write_agent!(project, "refactorer", "Read, Edit")

      messages = Catalog.build_messages(project)
      note = Enum.find(messages, &String.contains?(&1, "require edit mode"))

      assert note
      assert note =~ "2 additional Claude Code agents require edit mode"
      refute note =~ "You have these skills"
    end
  end
end
