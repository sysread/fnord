defmodule AI.Notes.ExternalDocsTest do
  use Fnord.TestCase
  import ExUnit.CaptureLog

  alias AI.Notes.ExternalDocs

  describe "project and cwd file discovery" do
    setup do
      # Create a mock project and switch to it for all tests in this group
      project = mock_project("test_external_docs")
      project_root = project.source_root

      original_cwd = File.cwd!()
      File.cd!(project_root)
      on_exit(fn -> File.cd!(original_cwd) end)

      {:ok, project: project, project_root: project_root}
    end

    test "finds docs in project root", %{project_root: project_root} do
      # Create test files in the mock project root
      claude_path = Path.join(project_root, "CLAUDE.md")
      agents_path = Path.join(project_root, "AGENTS.md")

      File.write!(claude_path, "Project root Claude docs")
      File.write!(agents_path, "Project root Agents docs")

      docs = ExternalDocs.get_docs()

      # Check that the docs contain the expected files from our mock project
      assert Enum.any?(docs, fn {type, path, _display, content} ->
               type == :claude and String.ends_with?(path, "CLAUDE.md") and
                 content == "Project root Claude docs"
             end)

      assert Enum.any?(docs, fn {type, path, _display, content} ->
               type == :agents and String.ends_with?(path, "AGENTS.md") and
                 content == "Project root Agents docs"
             end)
    end

    test "finds docs in cwd", %{project_root: project_root} do
      # Create test files in the current working directory (which is our mock project)
      claude_path = Path.join(project_root, "CLAUDE.md")
      agents_path = Path.join(project_root, "AGENTS.md")

      File.write!(claude_path, "Cwd Claude docs")
      File.write!(agents_path, "Cwd Agents docs")

      docs = ExternalDocs.get_docs()

      # The files should be found as cwd files with "./CLAUDE.md" display paths
      assert Enum.any?(docs, fn {type, _path, display, content} ->
               type == :claude and display == "./CLAUDE.md" and content == "Cwd Claude docs"
             end)

      assert Enum.any?(docs, fn {type, _path, display, content} ->
               type == :agents and display == "./AGENTS.md" and content == "Cwd Agents docs"
             end)
    end

    test "finds README.md in project root", %{project_root: project_root} do
      # Create README.md in the mock project root
      readme_path = Path.join(project_root, "README.md")
      File.write!(readme_path, "Project root README contents")

      docs = ExternalDocs.get_docs()

      assert Enum.any?(docs, fn {type, path, _display, content} ->
               type == :readme and String.ends_with?(path, "README.md") and
                 content == "Project root README contents"
             end)
    end

    test "finds README.md in cwd", %{project_root: project_root} do
      # Create README.md in the current working directory (mock project)
      readme_path = Path.join(project_root, "README.md")
      File.write!(readme_path, "Cwd README contents")

      docs = ExternalDocs.get_docs()

      assert Enum.any?(docs, fn {type, _path, display, content} ->
               type == :readme and display == "./README.md" and
                 content == "Cwd README contents"
             end)
    end
  end

  describe "home directory file discovery" do
    setup %{home_dir: home_dir} do
      # Override HOME environment to use the mock home directory from Fnord.TestCase
      original_home = System.get_env("HOME")
      System.put_env("HOME", home_dir)

      on_exit(fn ->
        if original_home,
          do: System.put_env("HOME", original_home),
          else: System.delete_env("HOME")
      end)

      :ok
    end

    test "finds docs in user home directories", %{home_dir: home_dir} do
      # Create the standard home directory structure for external docs
      claude_home1 = Path.join(home_dir, ".claude/CLAUDE.md")
      claude_home2 = Path.join(home_dir, ".config/claude/CLAUDE.md")
      agents_home1 = Path.join(home_dir, ".agents/AGENTS.md")
      agents_home2 = Path.join(home_dir, ".config/agents/AGENTS.md")

      # Create directory structure and write test files
      File.mkdir_p!(Path.dirname(claude_home1))
      File.write!(claude_home1, "Home Claude doc 1")

      File.mkdir_p!(Path.dirname(claude_home2))
      File.write!(claude_home2, "Home Claude doc 2")

      File.mkdir_p!(Path.dirname(agents_home1))
      File.write!(agents_home1, "Home Agents doc 1")

      File.mkdir_p!(Path.dirname(agents_home2))
      File.write!(agents_home2, "Home Agents doc 2")

      docs = ExternalDocs.get_docs()

      # Verify our mock home directory files are found with correct display paths
      assert {:claude, claude_home1, "~/.claude/CLAUDE.md", "Home Claude doc 1"} in docs
      assert {:claude, claude_home2, "~/.config/claude/CLAUDE.md", "Home Claude doc 2"} in docs
      assert {:agents, agents_home1, "~/.agents/AGENTS.md", "Home Agents doc 1"} in docs
      assert {:agents, agents_home2, "~/.config/agents/AGENTS.md", "Home Agents doc 2"} in docs

      # Verify we have exactly the expected home directory files (from our mock home)
      home_docs =
        Enum.filter(docs, fn {_type, path, _display, _content} ->
          String.starts_with?(path, home_dir)
        end)

      assert length(home_docs) == 4
    end
  end

  describe "file handling edge cases" do
    setup do
      # Basic temp directory setup for file handling tests
      original_cwd = File.cwd!()
      {:ok, cwd} = tmpdir()
      File.cd!(cwd)
      on_exit(fn -> File.cd!(original_cwd) end)
      {:ok, cwd: cwd}
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
          # The large file should be skipped, but other CLAUDE files may still be found
          # Check that none of the found docs have the large content
          refute Enum.any?(docs, fn {type, path, _, contents} ->
                   type == :claude and path == claude_path and byte_size(contents) > 1_000_000
                 end)
        end)

      assert log =~ "Skipping large file"
      assert log =~ claude_path
    end
  end

  describe "format_hints/1" do
    test "formats and truncates hints correctly" do
      # Prepare a single doc with content longer than hint_max_size
      docs = [
        {:readme, "/path/README.md", "README.md", String.duplicate("a", 5000)}
      ]

      result = ExternalDocs.format_hints(docs)

      # Should start with header and title
      assert String.starts_with?(result, "# Hints\n\n## README")

      # Should include exactly hint_max_size characters of content
      snippet = String.duplicate("a", 4096)
      assert String.contains?(result, snippet)
      refute String.contains?(result, String.duplicate("a", 4097))

      # Overall length should not exceed hint_max_size plus reasonable overhead
      assert String.length(result) <= 4096 + 50
    end
  end
end
