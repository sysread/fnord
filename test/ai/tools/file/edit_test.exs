defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("edit-test")
    {:ok, project: project}
  end

  setup do
    :meck.new(AI.Agent.Code.Patcher, [:no_link, :non_strict, :passthrough])
    on_exit(fn -> :meck.unload(AI.Agent.Code.Patcher) end)
    :ok
  end

  setup do
    Settings.set_edit_mode(true)
    Settings.set_auto_approve(true)

    on_exit(fn ->
      Settings.set_edit_mode(false)
      Settings.set_auto_approve(false)
    end)
  end

  test "call/1", %{project: project} do
    file =
      mock_source_file(project, "example.txt", """
      This is an example file.
      It contains some text that we will edit.
      How now, brown cow?
      """)

    :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
      assert args[:file] == file

      assert args[:changes] == [
               ~s{Replace the word "cow" with "bureaucrat" in the final sentence.}
             ]

      {:ok,
       """
       This is an example file.
       It contains some text that we will edit.
       How now, brown bureaucrat?
       """}
    end)

    assert {:ok, result} =
             Edit.call(%{
               "file" => file,
               "changes" => [
                 %{
                   "instructions" => """
                   Replace the word "cow" with "bureaucrat" in the final sentence.
                   """
                 }
               ]
             })

    assert result.diff =~ "-How now, brown cow?"
    assert result.diff =~ "+How now, brown bureaucrat?"
    assert result.file == file
    assert result.backup_file == file <> ".0.0.bak"
    assert File.exists?(result.backup_file)

    assert :meck.num_calls(AI.Agent.Code.Patcher, :get_response, :_) == 1
  end

  describe "create_if_missing" do
    test "file is created and patch applied", %{project: project} do
      path = Path.join(project.source_root, "newdir/foo.txt")
      refute File.exists?(path)

      :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
        assert args[:file] == path
        {:ok, "Line One\n"}
      end)

      {:ok, res} =
        Edit.call(%{
          "file" => path,
          "create_if_missing" => true,
          "changes" => [%{"instructions" => "Add first line"}]
        })

      assert File.exists?(path)
      # Diff headers use labels "ORIGINAL" and "MODIFIED" for new files
      assert res.diff =~ "--- ORIGINAL"
      assert res.diff =~ "+Line One"
      assert res.backup_file == ""
    end

    test "fails when missing and create_if_missing false", %{project: project} do
      path = Path.join(project.source_root, "nope.txt")

      assert {:error, msg} =
               Edit.call(%{"file" => path, "changes" => [%{"instructions" => "X"}]})

      assert msg =~ "File does not exist"
    end
  end

  describe "exact string matching" do
    test "exact replacement with old_string and new_string", %{project: project} do
      file =
        mock_source_file(project, "test.txt", """
        Hello World
        This is a test file.
        Goodbye World
        """)

      {:ok, result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "instructions" => "Replace greeting",
              "old_string" => "Hello World",
              "new_string" => "Hi Universe"
            }
          ]
        })

      assert result.diff =~ "-Hello World"
      assert result.diff =~ "+Hi Universe"

      # Verify AI patcher was not called for exact matching
      assert :meck.num_calls(AI.Agent.Code.Patcher, :get_response, :_) == 0
    end

    test "exact replacement with multiple occurrences fails without replace_all", %{
      project: project
    } do
      file =
        mock_source_file(project, "test.txt", """
        foo bar foo
        Another foo here
        """)

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Replace foo",
                     "old_string" => "foo",
                     "new_string" => "baz"
                   }
                 ]
               })

      assert msg =~ "String appears 3 times in file"
      assert msg =~ "Set replace_all: true"
    end

    test "exact replacement with replace_all true", %{project: project} do
      file =
        mock_source_file(project, "test.txt", """
        foo bar foo
        Another foo here
        """)

      {:ok, result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "instructions" => "Replace all foo",
              "old_string" => "foo",
              "new_string" => "baz",
              "replace_all" => true
            }
          ]
        })

      assert result.diff =~ "-foo bar foo"
      assert result.diff =~ "+baz bar baz"
      assert result.diff =~ "-Another foo here"
      assert result.diff =~ "+Another baz here"
    end

    test "exact replacement with string not found", %{project: project} do
      file =
        mock_source_file(project, "test.txt", """
        Hello World
        This is a test.
        """)

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Replace missing text",
                     "old_string" => "missing text",
                     "new_string" => "found text"
                   }
                 ]
               })

      assert msg =~ "String not found in file"
      assert msg =~ "missing text"
    end

    test "exact replacement preserves whitespace", %{project: project} do
      file =
        mock_source_file(project, "test.py", """
        def hello():
            print("Hello")
            return True
        """)

      {:ok, _result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "instructions" => "Change print statement",
              "old_string" => "    print(\"Hello\")",
              "new_string" => "    print(\"Hi there\")"
            }
          ]
        })

      # Verify the file contents have correct indentation
      contents = File.read!(file)
      assert String.contains?(contents, "    print(\"Hi there\")")
      refute String.contains?(contents, "print(\"Hello\")")
    end

    test "exact replacement uses whitespace fitter for multi-line hunks", %{project: project} do
      file =
        mock_source_file(project, "test_go_like.txt", """
        package main

        import "fmt"

        func main() {
        	fmt.Println("hello")
        }
        """)

      # Intentionally provide a space-indented replacement for a tab-indented line
      {:ok, _result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "instructions" => "Change Go-style print",
              "old_string" => "\tfmt.Println(\"hello\")",
              "new_string" => "    fmt.Println(\"hi\")\n        fmt.Println(\"there\")"
            }
          ]
        })

      contents = File.read!(file)

      # WhitespaceFitter should have normalized indentation to tabs, preserving
      # relative depth between lines.
      assert String.contains?(contents, "\tfmt.Println(\"hi\")")
      assert String.contains?(contents, "\t\tfmt.Println(\"there\")")
      refute String.contains?(contents, "fmt.Println(\"hello\")")
    end

    test "raw replacement skips whitespace fitter when FNORD_NO_FITTING is true", %{
      project: project
    } do
      file =
        mock_source_file(project, "test_go_like.txt", """
        package main

        import "fmt"

        func main() {
        	fmt.Println("hello")
        }
        """)

      Util.Env.put_env("FNORD_NO_FITTING", "true")
      on_exit(fn -> System.delete_env("FNORD_NO_FITTING") end)

      {:ok, _result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "instructions" => "Change Go-style print without whitespace fitting",
              "old_string" => "\tfmt.Println(\"hello\")",
              "new_string" => "    fmt.Println(\"hi\")\n        fmt.Println(\"there\")"
            }
          ]
        })

      contents = File.read!(file)

      assert String.contains?(contents, "    fmt.Println(\"hi\")")
      assert String.contains?(contents, "        fmt.Println(\"there\")")
      refute String.contains?(contents, "\tfmt.Println(\"hi\")")
      refute String.contains?(contents, "\t\tfmt.Println(\"there\")")
      refute String.contains?(contents, "fmt.Println(\"hello\")")
    end

    test "mixed exact and natural language changes", %{project: project} do
      file =
        mock_source_file(project, "test.txt", """
        # Header
        Hello World
        Some content here
        # Footer
        """)

      # Mock the natural language change
      :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
        assert args[:changes] == ["Add a new line after the header"]

        {:ok,
         """
         # Header
         This is new content
         Hi Universe
         Some content here
         # Footer
         """}
      end)

      {:ok, _result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "instructions" => "Replace greeting exactly",
              "old_string" => "Hello World",
              "new_string" => "Hi Universe"
            },
            %{
              "instructions" => "Add a new line after the header"
            }
          ]
        })

      # Verify both changes are reflected in the final file
      final_content = File.read!(file)
      assert String.contains?(final_content, "Hi Universe")
      assert String.contains?(final_content, "This is new content")
      refute String.contains?(final_content, "Hello World")

      # Verify AI patcher was called only once (for natural language change)
      assert :meck.num_calls(AI.Agent.Code.Patcher, :get_response, :_) == 1
    end
  end

  describe "validation" do
    test "empty old_string fails validation", %{project: project} do
      file = mock_source_file(project, "test.txt", "content")

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Bad change",
                     "old_string" => "",
                     "new_string" => "new"
                   }
                 ]
               })

      assert msg =~ "old_string cannot be empty"
    end

    test "vague natural language instruction fails validation", %{project: project} do
      file = mock_source_file(project, "test.txt", "content")

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [%{"instructions" => "fix it"}]
               })

      assert msg =~ "Instruction too vague"
    end

    test "natural language without anchors fails validation", %{project: project} do
      file = mock_source_file(project, "test.txt", "content")

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [%{"instructions" => "change something somewhere somehow"}]
               })

      assert msg =~ "lacks clear location anchors"
    end

    test "partial exact string parameters fail validation", %{project: project} do
      file = mock_source_file(project, "test.txt", "content")

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Partial change",
                     "old_string" => "old"
                     # missing new_string
                   }
                 ]
               })

      assert msg =~ "Both old_string and new_string must be provided together"
    end

    test "file creation with exact string matching", %{project: project} do
      path = Path.join(project.source_root, "new_file.txt")
      refute File.exists?(path)

      {:ok, result} =
        Edit.call(%{
          "file" => path,
          "create_if_missing" => true,
          "changes" => [
            %{
              "instructions" => "Create new file",
              "old_string" => "",
              "new_string" => "Hello World\nThis is a new file."
            }
          ]
        })

      assert File.exists?(path)
      assert result.backup_file == ""
      assert result.diff =~ "+Hello World"
      assert result.diff =~ "+This is a new file."

      # Verify actual file content
      content = File.read!(path)
      assert content == "Hello World\nThis is a new file."
    end

    test "file creation with omitted old_string (improved UX)", %{project: project} do
      path = Path.join(project.source_root, "simple_new_file.txt")
      refute File.exists?(path)

      {:ok, result} =
        Edit.call(%{
          "file" => path,
          "create_if_missing" => true,
          "changes" => [
            %{
              "instructions" => "Create simple file",
              "new_string" => "Just the content\nNo old_string needed!"
            }
          ]
        })

      assert File.exists?(path)
      assert result.backup_file == ""
      assert result.diff =~ "+Just the content"
      assert result.diff =~ "+No old_string needed!"

      # Verify actual file content
      content = File.read!(path)
      assert content == "Just the content\nNo old_string needed!"

      # Verify AI patcher was not called (exact string matching)
      assert :meck.num_calls(AI.Agent.Code.Patcher, :get_response, :_) == 0
    end
  end

  describe "language agnostic operation" do
    test "works with various file types", %{project: project} do
      test_cases = [
        {"config.json", ~s|{"key": "old_value"}|, "old_value", "new_value",
         ~s|{"key": "new_value"}|},
        {"style.css", ".class { color: red; }", "red", "blue", ".class { color: blue; }"},
        {"data.xml", "<item>old</item>", "old", "new", "<item>new</item>"},
        {"README.md", "# Old Title", "Old Title", "New Title", "# New Title"},
        {"script.sh", "echo 'hello'", "hello", "world", "echo 'world'"},
        {"config.toml", "value = 'old'", "old", "new", "value = 'new'"}
      ]

      for {filename, content, old, new, expected_content} <- test_cases do
        file = mock_source_file(project, filename, content)

        {:ok, result} =
          Edit.call(%{
            "file" => file,
            "changes" => [
              %{
                "instructions" => "Update content",
                "old_string" => old,
                "new_string" => new
              }
            ]
          })

        # Verify the diff shows the changes (may include surrounding context)
        assert result.diff =~ "-"
        assert result.diff =~ "+"

        # Verify the actual file content is correct
        final_content = File.read!(file)
        assert String.contains?(final_content, expected_content)
        refute String.contains?(final_content, old)
      end
    end
  end
end
