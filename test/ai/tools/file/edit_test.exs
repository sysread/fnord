defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("edit-test")
    # Set override so the worktree gate passes (we're in a git repo)
    Settings.set_project_root_override(project.source_root)
    on_exit(fn -> Settings.set_project_root_override(nil) end)
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

  test "call/1 allows edits for non-git project roots without override", %{project: project} do
    Settings.set_project_root_override(nil)

    file =
      mock_source_file(project, "non_git.txt", """
      alpha
      beta
      """)

    :meck.expect(GitCli, :is_git_repo?, fn -> false end)

    assert {:ok, result} =
             Edit.call(%{
               "file" => file,
               "changes" => [
                 %{"old_string" => "beta", "new_string" => "gamma"}
               ]
             })

    assert result.diff =~ "-beta"
    assert result.diff =~ "+gamma"
    assert File.read!(file) == "alpha\ngamma\n"
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

    test "exact replacement matches through typographic normalization", %{project: project} do
      # File contains smart quotes and em dash; LLM sends ASCII equivalents
      file =
        mock_source_file(project, "test.txt", "it\u2019s a \u201Csmart\u201D world \u2014 indeed")

      assert {:ok, _result} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Replace text",
                     "old_string" => "it's a \"smart\" world -- indeed",
                     "new_string" => "it is a plain world - indeed"
                   }
                 ]
               })

      assert File.read!(file) == "it is a plain world - indeed"
    end

    test "whitespace-normalized matching recovers wrong indentation", %{project: project} do
      # File uses 4-space indentation; LLM sends 2-space version
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
              "instructions" => "Replace print and return",
              "old_string" => "  print(\"Hello\")\n  return True",
              "new_string" => "    print(\"Hi\")\n    return False"
            }
          ]
        })

      contents = File.read!(file)
      assert String.contains?(contents, "print(\"Hi\")")
      assert String.contains?(contents, "return False")
      refute String.contains?(contents, "print(\"Hello\")")
    end

    test "whitespace-normalized matching rejects ambiguous matches", %{project: project} do
      # Two identical blocks with different indentation - normalization would
      # match both, so it should fall back to error rather than guess
      file =
        mock_source_file(project, "test.py", """
        def foo():
            print("hello")
            return True

        def bar():
              print("hello")
              return True
        """)

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Replace",
                     "old_string" => "  print(\"hello\")\n  return True",
                     "new_string" => "  print(\"world\")\n  return False"
                   }
                 ]
               })

      assert msg =~ "String not found"
    end

    test "whitespace-normalized matching skips single-line old_string", %{project: project} do
      # Single-line whitespace mismatch should NOT be fuzzy-matched since
      # stripping leading whitespace on one line is too likely to be ambiguous.
      # Use tab-indented file with space-indented old_string to ensure
      # byte-exact match fails.
      file =
        mock_source_file(project, "test.go", "func main() {\n\tx = 1\n}")

      assert {:error, _msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Replace",
                     "old_string" => "    x = 1",
                     "new_string" => "\tx = 2"
                   }
                 ]
               })
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

  describe "hash-anchored replacement" do
    # Builds "line:hash" identifiers for the given content string and 1-based
    # line range. Mirrors what file_contents_tool produces for the LLM.
    defp hashline_ids(content, first_line, last_line) do
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {_line, idx} -> idx >= first_line and idx <= last_line end)
      |> Enum.map(fn {line, idx} -> "#{idx}:#{Util.line_hash(line)}" end)
    end

    test "replaces lines identified by line:hash identifiers", %{project: project} do
      content = "line one\nline two\nline three\nline four"
      file = mock_source_file(project, "test.txt", content)

      hashes = hashline_ids(content, 2, 3)

      {:ok, result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "hashes" => hashes,
              "old_string" => "line two\nline three",
              "new_string" => "replaced two\nreplaced three"
            }
          ]
        })

      assert result.diff =~ "-line two"
      assert result.diff =~ "+replaced two"

      final = File.read!(file)
      assert final =~ "replaced two\nreplaced three"
      assert final =~ "line one"
      assert final =~ "line four"

      # Verify patcher was not called
      assert :meck.num_calls(AI.Agent.Code.Patcher, :get_response, :_) == 0
    end

    test "single-line edit succeeds", %{project: project} do
      content = "aaa\nbbb\nccc"
      file = mock_source_file(project, "test.txt", content)

      hashes = hashline_ids(content, 2, 2)

      {:ok, _result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "hashes" => hashes,
              "old_string" => "bbb",
              "new_string" => "replaced"
            }
          ]
        })

      final = File.read!(file)
      assert final == "aaa\nreplaced\nccc"
    end

    test "rejects when old_string doesn't match hash-identified region", %{project: project} do
      content = "line one\nline two\nline three"
      file = mock_source_file(project, "test.txt", content)

      hashes = hashline_ids(content, 2, 3)

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "hashes" => hashes,
                     "old_string" => "wrong content\ncompletely different",
                     "new_string" => "whatever"
                   }
                 ]
               })

      assert msg =~ "old_string does not match"
      assert msg =~ "copy error"
    end

    test "old_string verification is whitespace-tolerant", %{project: project} do
      # File has 4-space indentation; old_string uses 2-space
      content = "def foo():\n    print('hello')\n    return True"
      file = mock_source_file(project, "test.txt", content)

      hashes = hashline_ids(content, 2, 3)

      {:ok, _result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "hashes" => hashes,
              "old_string" => "  print('hello')\n  return True",
              "new_string" => "print('hi')\nreturn False"
            }
          ]
        })

      final = File.read!(file)
      assert final =~ "print('hi')"
      assert final =~ "return False"
    end

    test "rejects when hash doesn't match (file changed)", %{project: project} do
      file = mock_source_file(project, "test.txt", "line one\nline two\nline three")

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "hashes" => ["2:dead", "3:beef"],
                     "old_string" => "whatever\nwhatever",
                     "new_string" => "whatever"
                   }
                 ]
               })

      assert msg =~ "Hash mismatch"
      assert msg =~ "file may have changed"
    end

    test "rejects non-contiguous line numbers", %{project: project} do
      content = "aaa\nbbb\nccc\nddd"
      file = mock_source_file(project, "test.txt", content)

      # Lines 1 and 3 (skipping 2)
      hashes = [
        "1:#{Util.line_hash("aaa")}",
        "3:#{Util.line_hash("ccc")}"
      ]

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "hashes" => hashes,
                     "old_string" => "aaa\nccc",
                     "new_string" => "whatever"
                   }
                 ]
               })

      assert msg =~ "contiguous"
    end

    test "rejects line number out of range", %{project: project} do
      content = "aaa\nbbb"
      file = mock_source_file(project, "test.txt", content)

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "hashes" => ["5:abcd"],
                     "old_string" => "whatever",
                     "new_string" => "whatever"
                   }
                 ]
               })

      assert msg =~ "out of range"
    end

    test "correct line number but wrong hash is rejected", %{project: project} do
      content = "alpha\nbeta\ngamma"
      file = mock_source_file(project, "test.txt", content)

      # Right line number, wrong hash
      hashes = ["2:ffff"]

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "hashes" => hashes,
                     "old_string" => "beta",
                     "new_string" => "whatever"
                   }
                 ]
               })

      assert msg =~ "Hash mismatch"
      assert msg =~ "line 2"
    end

    test "applies whitespace fitting to new_string", %{project: project} do
      content = "func main() {\n\tfmt.Println(\"hello\")\n\tfmt.Println(\"world\")\n}"
      file = mock_source_file(project, "test.txt", content)

      hashes = hashline_ids(content, 2, 3)

      {:ok, _result} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "hashes" => hashes,
              "old_string" => "\tfmt.Println(\"hello\")\n\tfmt.Println(\"world\")",
              "new_string" => "fmt.Println(\"hi\")\nfmt.Println(\"there\")"
            }
          ]
        })

      final = File.read!(file)
      assert String.contains?(final, "\tfmt.Println(\"hi\")")
      assert String.contains?(final, "\tfmt.Println(\"there\")")
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
                 "changes" => [%{"instructions" => "make it work better and also be nicer"}]
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

    test "rejects old_string containing hashline prefixes", %{project: project} do
      file = mock_source_file(project, "test.txt", "defmodule Foo do\n  def bar, do: :ok\nend")

      assert {:error, msg} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "old_string" => "1:8631|defmodule Foo do\n2:e716|  def bar, do: :ok",
                     "new_string" => "defmodule Foo do\n  def baz, do: :ok"
                   }
                 ]
               })

      assert msg =~ "hashline prefixes"
      assert msg =~ "raw file text"
    end

    test "allows old_string that looks like hashline but is real file content", %{
      project: project
    } do
      # CSV-like content where `1:a3f1|` is actual data in the file
      content = "1:a3f1|data,value\n2:f10e|other,stuff"
      file = mock_source_file(project, "data.csv", content)

      assert {:ok, _result} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "old_string" => "1:a3f1|data,value",
                     "new_string" => "1:a3f1|updated,value"
                   }
                 ]
               })

      assert File.read!(file) =~ "updated,value"
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

  describe "natural language context passthrough" do
    test "context is passed to Patcher when provided", %{project: project} do
      file =
        mock_source_file(project, "ctx.txt", """
        Original content here.
        """)

      :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
        assert args[:file] == file
        assert args[:context] == "This file uses tab indentation and camelCase naming."

        assert args[:changes] == [
                 "Add a new function after the existing content"
               ]

        {:ok, "Original content here.\ndef newFunc(): pass\n"}
      end)

      assert {:ok, _result} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Add a new function after the existing content",
                     "context" => "This file uses tab indentation and camelCase naming."
                   }
                 ]
               })

      assert :meck.num_calls(AI.Agent.Code.Patcher, :get_response, :_) == 1
    end

    test "context is nil when not provided", %{project: project} do
      file =
        mock_source_file(project, "noctx.txt", """
        Some content.
        """)

      :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
        assert args[:context] == nil
        {:ok, "Some content.\nMore content.\n"}
      end)

      assert {:ok, _result} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Add more content after the existing line"
                   }
                 ]
               })
    end

    test "empty string context is treated as nil", %{project: project} do
      file =
        mock_source_file(project, "emptyctx.txt", """
        Content here.
        """)

      :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
        assert args[:context] == nil
        {:ok, "Content here.\nNew stuff.\n"}
      end)

      assert {:ok, _result} =
               Edit.call(%{
                 "file" => file,
                 "changes" => [
                   %{
                     "instructions" => "Add new stuff after the existing content",
                     "context" => ""
                   }
                 ]
               })
    end
  end
end
