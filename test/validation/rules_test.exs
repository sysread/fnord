defmodule Validation.RulesTest do
  use Fnord.TestCase, async: false

  test "matches changed files against glob rules and deduplicates commands" do
    rules = [
      %{path_globs: ["lib/**/*.ex"], command: "mix format"},
      %{path_globs: ["lib/**/*.ex", "test/**/*.exs"], command: "mix test"},
      %{path_globs: ["README.md"], command: "mix format"}
    ]

    changed_files = ["lib/foo/fnord.ex", "test/fnord_test.exs"]

    assert ["mix format", "mix test"] ==
             Validation.Rules.matching_commands(rules, changed_files)
  end

  test "supports brace expansion in glob matching" do
    changed_files = ["docs/sub/guide.md"]

    assert Validation.Rules.glob_matches_any_changed_file?(
             "{test,lib,docs}/**/*.md",
             changed_files
           )
  end

  test "** matches zero intermediate directories" do
    assert Validation.Rules.glob_matches_any_changed_file?(
             "docs/**/*.md",
             ["docs/guide.md"]
           )

    assert Validation.Rules.glob_matches_any_changed_file?(
             "docs/**/*.md",
             ["docs/sub/guide.md"]
           )

    assert Validation.Rules.glob_matches_any_changed_file?(
             "**/*.ex",
             ["foo.ex"]
           )
  end

  test "matching_commands/2 selects commands for multiple path_glob entries" do
    rules = [
      %{
        path_globs: ["{test,lib,docs}/**/*.md", "README.md"],
        command: "markdownlint-cli2 --config .markdownlint.json {test,lib,docs}/**/*.md README.md"
      }
    ]

    assert ["markdownlint-cli2 --config .markdownlint.json {test,lib,docs}/**/*.md README.md"] ==
             Validation.Rules.matching_commands(rules, ["docs/sub/guide.md"])

    assert ["markdownlint-cli2 --config .markdownlint.json {test,lib,docs}/**/*.md README.md"] ==
             Validation.Rules.matching_commands(rules, ["README.md"])
  end

  test "matches project-root sentinel path glob" do
    assert ["mix format"] ==
             Validation.Rules.matching_commands(
               [%{path_globs: ["."], command: "mix format"}],
               ["lib/fnord.ex"]
             )
  end

  test "summarize/1 exposes the no-changes public contract" do
    # The sentinel path glob test above documents rule-level matching with changed files.
    # The no-changes boundary is public via summarize/1, not private helper calls.
    assert "Validation skipped: no changed files detected." ==
             Validation.Rules.summarize({:ok, :no_changes})
  end

  test "expands braces recursively" do
    assert ["lib/src/*.ex", "lib/test/*.ex", "test/src/*.ex", "test/test/*.ex"] ==
             Validation.Rules.expand_braces("{lib,test}/{src,test}/*.ex")
  end

  test "expands nested braces from inside out" do
    expanded =
      "{lib/{src,test},docs}/*.ex"
      |> Validation.Rules.expand_braces()
      |> Enum.uniq()
      |> Enum.sort()

    assert expanded == ["docs/*.ex", "lib/src/*.ex", "lib/test/*.ex"]
  end

  test "expands glob argv tokens relative to the project root" do
    root = tmpdir() |> elem(1)
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "README.md"), "# hi\n")
    File.write!(Path.join(root, "docs/guide.md"), "# guide\n")

    assert ["docs/guide.md", "README.md"] ==
             Validation.Rules.expand_argv(
               ["{docs/**/*.md,README.md}"],
               root
             )
  end

  test "keeps unmatched glob argv tokens literal" do
    root = tmpdir() |> elem(1)

    assert ["docs/**/*.md"] ==
             Validation.Rules.expand_argv(["docs/**/*.md"], root)
  end

  test "parses command strings with quotes and expands argv" do
    root = tmpdir() |> elem(1)
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "docs/guide one.md"), "# guide\n")

    assert {"markdownlint-cli2", ["docs/guide one.md"]} ==
             Validation.Rules.expand_command(
               "markdownlint-cli2 \"docs/*.md\"",
               root
             )
  end

  test "fingerprint is stable regardless of changed-file order" do
    a = Validation.Rules.fingerprint(["b.ex", "a.ex"])
    b = Validation.Rules.fingerprint(["a.ex", "b.ex"])

    assert a == b
  end

  describe "execute_validation_command/2" do
    test "executes validation commands directly" do
      project = mock_project("validation-exec")
      Settings.set_project(project.name)

      assert {:ok, %{command: "echo ok", status: 0, output: output}} =
               Validation.Rules.execute_validation_command(
                 "echo ok",
                 project.source_root
               )

      assert output =~ "ok"
    end

    test "returns a structured failure for non-zero exit commands" do
      project = mock_project("validation-failure")
      Settings.set_project(project.name)

      assert {:error, %{command: "false", status: status, output: output}} =
               Validation.Rules.execute_validation_command(
                 "false",
                 project.source_root
               )

      assert status == 1
      assert is_binary(output)
    end

    test "preserves structured success result shape" do
      project = mock_project("validation-success")
      Settings.set_project(project.name)

      assert {:ok, result} =
               Validation.Rules.execute_validation_command(
                 "echo done",
                 project.source_root
               )

      assert [:command, :output, :status] == result |> Map.keys() |> Enum.sort()
      assert result.command == "echo done"
      assert result.status == 0
    end
  end
end
