defmodule AI.Notes.ExternalDocsTest do
  use Fnord.TestCase
  import ExUnit.CaptureLog

  alias AI.Notes.ExternalDocs

  describe "get_docs/0" do
    setup do
      # Temporarily switch to an isolated working directory
      original_cwd = File.cwd!()
      {:ok, cwd} = tmpdir()
      File.cd!(cwd)
      on_exit(fn -> File.cd!(original_cwd) end)
      {:ok, cwd: cwd}
    end

    test "finds docs in project root", %{cwd: _cwd} do
      # Project root is always Path.expand("../../../", __DIR__)
      project_root = Path.expand("../../../", __DIR__)
      claude_path = Path.join(project_root, "CLAUDE.md")
      agents_path = Path.join(project_root, "AGENTS.md")

      # Drop both files into project root
      File.write!(claude_path, "Project root Claude docs")
      File.write!(agents_path, "Project root Agents docs")

      # Ensure cleanup after test
      on_exit(fn ->
        File.rm_rf!(claude_path)
        File.rm_rf!(agents_path)
      end)

      docs = ExternalDocs.get_docs()

      # Check that the docs contain the expected files (ignoring display paths for now)
      assert Enum.any?(docs, fn {type, path, _display, content} -> 
        type == :claude and path == claude_path and content == "Project root Claude docs"
      end)
      assert Enum.any?(docs, fn {type, path, _display, content} -> 
        type == :agents and path == agents_path and content == "Project root Agents docs"
      end)
    end

    test "finds docs in cwd", %{cwd: cwd} do
      claude_path = Path.join(cwd, "CLAUDE.md")
      agents_path = Path.join(cwd, "AGENTS.md")

      File.write!(claude_path, "Cwd Claude docs")
      File.write!(agents_path, "Cwd Agents docs")

      docs = ExternalDocs.get_docs()

      # Use File.cwd! to get the same path resolution as ExternalDocs
      actual_cwd = File.cwd!()
      expected_claude_path = Path.join(actual_cwd, "CLAUDE.md")
      expected_agents_path = Path.join(actual_cwd, "AGENTS.md")

      assert {:claude, expected_claude_path, "./CLAUDE.md", "Cwd Claude docs"} in docs
      assert {:agents, expected_agents_path, "./AGENTS.md", "Cwd Agents docs"} in docs
    end

    test "finds docs in user home directories", %{home_dir: home_dir} do
      claude_home1 = Path.join(home_dir, ".claude/CLAUDE.md")
      claude_home2 = Path.join(home_dir, ".config/claude/CLAUDE.md")
      agents_home1 = Path.join(home_dir, ".agents/AGENTS.md")
      agents_home2 = Path.join(home_dir, ".config/agents/AGENTS.md")

      # Create and write into each user-location
      File.mkdir_p!(Path.dirname(claude_home1))
      File.write!(claude_home1, "Home Claude doc 1")

      File.mkdir_p!(Path.dirname(claude_home2))
      File.write!(claude_home2, "Home Claude doc 2")

      File.mkdir_p!(Path.dirname(agents_home1))
      File.write!(agents_home1, "Home Agents doc 1")

      File.mkdir_p!(Path.dirname(agents_home2))
      File.write!(agents_home2, "Home Agents doc 2")

      System.put_env("HOME", home_dir)
      docs = ExternalDocs.get_docs()

      assert length(docs) == 4
      assert {:claude, claude_home1, "~/.claude/CLAUDE.md", "Home Claude doc 1"} in docs
      assert {:claude, claude_home2, "~/.config/claude/CLAUDE.md", "Home Claude doc 2"} in docs
      assert {:agents, agents_home1, "~/.agents/AGENTS.md", "Home Agents doc 1"} in docs
      assert {:agents, agents_home2, "~/.config/agents/AGENTS.md", "Home Agents doc 2"} in docs
    end

    test "skips large files with warning", %{cwd: cwd} do
      claude_path = Path.join(cwd, "CLAUDE.md")
      # Write a file just above the 1MB threshold
      large_content = String.duplicate("x", 1_000_001)
      File.write!(claude_path, large_content)

      # Ensure warnings are captured
      set_log_level(:warning)

      log =
        capture_log(fn ->
          docs = ExternalDocs.get_docs()
          refute Enum.any?(docs, fn {type, _, _, _} -> type == :claude end)
        end)

      assert log =~ "Skipping large file"
      assert log =~ claude_path
    end
  end
end
