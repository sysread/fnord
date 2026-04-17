defmodule ExternalConfigs.AgentTest do
  use Fnord.TestCase, async: false

  alias ExternalConfigs.Agent

  defp write_agent!(dir, name, contents) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  test "parses an agent .md with frontmatter" do
    {:ok, dir} = tmpdir()

    path =
      write_agent!(dir, "review-pedantic.md", """
      ---
      name: review-pedantic
      description: Mechanical-correctness specialist.
      tools: Bash, Read, Grep, Glob
      model: sonnet
      ---
      You are a pedantic review agent.
      """)

    assert {:ok, agent} = Agent.from_file(path, :global)
    assert agent.name == "review-pedantic"
    assert agent.description == "Mechanical-correctness specialist."
    assert agent.tools == ["Bash", "Read", "Grep", "Glob"]
    assert agent.model == "sonnet"
    assert agent.source == :global
    assert agent.body =~ "You are a pedantic review agent."
  end

  test "falls back to filename when name frontmatter is absent" do
    {:ok, dir} = tmpdir()

    path =
      write_agent!(dir, "MyHelper.md", """
      ---
      description: helper
      ---
      body
      """)

    assert {:ok, agent} = Agent.from_file(path, :project)
    assert agent.name == "MyHelper"
    assert agent.source == :project
  end

  test "accepts tools as a YAML list" do
    {:ok, dir} = tmpdir()

    path =
      write_agent!(dir, "x.md", """
      ---
      name: x
      description: d
      tools:
        - Bash
        - Edit
      ---
      body
      """)

    assert {:ok, %{tools: ["Bash", "Edit"]}} = Agent.from_file(path, :project)
  end
end
