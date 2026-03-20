defmodule Settings.ValidationTest do
  use Fnord.TestCase, async: false

  test "returns empty list when project has no validation rules" do
    mock_project("demo")
    Settings.set_project("demo")

    assert [] == Settings.Validation.list()
    refute Settings.Validation.configured?()
  end

  test "normalizes valid project validation rules" do
    mock_project("demo")
    Settings.set_project("demo")
    settings = Settings.new()
    {:ok, project} = Store.get_project("demo")

    Settings.set_project_data(settings, "demo", %{
      "root" => project.source_root,
      "validation" => [
        %{"path_globs" => ["lib/**/*.ex"], "command" => "mix format"},
        %{"path_globs" => "README.md", "command" => " markdownlint-cli2 README.md "}
      ]
    })

    assert [
             %{path_globs: ["lib/**/*.ex"], command: "mix format"},
             %{path_globs: ["README.md"], command: "markdownlint-cli2 README.md"}
           ] = Settings.Validation.list()

    assert Settings.Validation.configured?()
  end

  test "ignores malformed entries safely" do
    mock_project("demo")
    Settings.set_project("demo")
    settings = Settings.new()
    {:ok, project} = Store.get_project("demo")

    Settings.set_project_data(settings, "demo", %{
      "root" => project.source_root,
      "validation" => [
        %{"path_globs" => [], "command" => "mix format"},
        %{"path_globs" => ["lib/**/*.ex"], "command" => "   "},
        %{"path_globs" => ["lib/**/*.ex"]},
        %{"command" => "mix test"},
        "nonsense",
        %{"path_globs" => ["test/**/*.exs"], "command" => "mix test"}
      ]
    })

    assert [
             %{path_globs: ["test/**/*.exs"], command: "mix test"}
           ] = Settings.Validation.list()
  end

  test "supports explicit project lookup" do
    alpha = mock_project("alpha")
    _beta = mock_project("beta")
    Settings.set_project("alpha")
    settings = Settings.new()
    {:ok, project} = Store.get_project("beta")

    Settings.set_project_data(settings, "beta", %{
      "root" => project.source_root,
      "validation" => [
        %{"path_globs" => ["docs/**/*.md"], "command" => "markdownlint-cli2 docs/**/*.md"}
      ]
    })

    assert [] == Settings.Validation.list()

    assert [
             %{path_globs: ["docs/**/*.md"], command: "markdownlint-cli2 docs/**/*.md"}
           ] = Settings.Validation.list("beta")

    {:ok, beta} = Store.get_project("beta")
    assert alpha.source_root != beta.source_root
  end

  test "splits space-separated path_globs into individual entries" do
    mock_project("demo")
    Settings.set_project("demo")
    settings = Settings.new()
    {:ok, project} = Store.get_project("demo")

    Settings.set_project_data(settings, "demo", %{
      "root" => project.source_root,
      "validation" => [
        %{
          "path_globs" => ["{test,lib,docs}/**/*.md README.md"],
          "command" => "markdownlint-cli2 {test,lib,docs}/**/*.md README.md"
        }
      ]
    })

    assert [
             %{
               path_globs: ["{test,lib,docs}/**/*.md", "README.md"],
               command: "markdownlint-cli2 {test,lib,docs}/**/*.md README.md"
             }
           ] = Settings.Validation.list()
  end

  test "splits space-separated path_globs when adding rules" do
    mock_project("demo")
    Settings.set_project("demo")

    assert {:ok,
            [
              %{
                path_globs: ["{test,lib,docs}/**/*.md", "README.md"],
                command: "markdownlint-cli2"
              }
            ]} =
             Settings.Validation.add_rule("markdownlint-cli2", [
               "{test,lib,docs}/**/*.md README.md"
             ])
  end

  describe "mutators" do
    test "add_rule trims command and globs" do
      mock_project("demo")
      Settings.set_project("demo")

      assert {:ok, [%{command: "mix format", path_globs: ["lib/**/*.ex", "test/**/*.exs"]}]} ==
               Settings.Validation.add_rule("  mix format  ", [
                 " lib/**/*.ex ",
                 " test/**/*.exs "
               ])

      assert Settings.Validation.list() == [
               %{command: "mix format", path_globs: ["lib/**/*.ex", "test/**/*.exs"]}
             ]
    end

    test "add_rule accepts explicit project-root sentinel glob" do
      mock_project("demo")
      Settings.set_project("demo")

      assert {:ok, [%{command: "mix test", path_globs: ["."]}]} ==
               Settings.Validation.add_rule("mix test", ["."])

      assert Settings.Validation.list() == [
               %{command: "mix test", path_globs: ["."]}
             ]
    end

    test "add_rule rejects blank globs and leaves rules unchanged" do
      mock_project("demo")
      Settings.set_project("demo")
      settings = Settings.new()
      {:ok, project} = Store.get_project("demo")

      Settings.set_project_data(settings, "demo", %{
        "root" => project.source_root,
        "validation" => [
          %{"path_globs" => ["lib/**/*.ex"], "command" => "mix format"}
        ]
      })

      assert {:error, :invalid_rule} ==
               Settings.Validation.add_rule("mix test", ["test/**/*.exs", "   "])

      assert Settings.Validation.list() == [
               %{command: "mix format", path_globs: ["lib/**/*.ex"]}
             ]
    end

    test "remove_rule uses displayed order from list" do
      mock_project("demo")
      Settings.set_project("demo")
      settings = Settings.new()
      {:ok, project} = Store.get_project("demo")

      Settings.set_project_data(settings, "demo", %{
        "root" => project.source_root,
        "validation" => [
          %{"path_globs" => ["lib/**/*.ex"], "command" => " mix format "},
          %{"path_globs" => [], "command" => "mix lint"},
          %{"path_globs" => ["test/**/*.exs"], "command" => " mix test "}
        ]
      })

      assert Settings.Validation.list() == [
               %{command: "mix format", path_globs: ["lib/**/*.ex"]},
               %{command: "mix test", path_globs: ["test/**/*.exs"]}
             ]

      assert {:ok, [%{command: "mix test", path_globs: ["test/**/*.exs"]}]} ==
               Settings.Validation.remove_rule(1)

      assert Settings.Validation.list() == [
               %{command: "mix test", path_globs: ["test/**/*.exs"]}
             ]
    end

    test "remove_rule returns error for invalid index and preserves rules" do
      mock_project("demo")
      Settings.set_project("demo")
      settings = Settings.new()
      {:ok, project} = Store.get_project("demo")

      Settings.set_project_data(settings, "demo", %{
        "root" => project.source_root,
        "validation" => [
          %{"path_globs" => ["lib/**/*.ex"], "command" => "mix format"}
        ]
      })

      assert {:error, :invalid_index} == Settings.Validation.remove_rule(2)

      assert Settings.Validation.list() == [
               %{command: "mix format", path_globs: ["lib/**/*.ex"]}
             ]
    end

    test "mutations clean malformed stored entries" do
      mock_project("demo")
      Settings.set_project("demo")
      settings = Settings.new()
      {:ok, project} = Store.get_project("demo")

      Settings.set_project_data(settings, "demo", %{
        "root" => project.source_root,
        "validation" => [
          %{"path_globs" => [], "command" => "mix format"},
          %{"path_globs" => ["lib/**/*.ex"], "command" => " mix format "},
          "nonsense",
          %{"command" => "mix test"}
        ]
      })

      assert {:ok,
              [
                %{command: "mix format", path_globs: ["lib/**/*.ex"]},
                %{command: "mix test", path_globs: ["test/**/*.exs"]}
              ]} ==
               Settings.Validation.add_rule("mix test", ["test/**/*.exs"])

      assert Settings.Validation.list() == [
               %{command: "mix format", path_globs: ["lib/**/*.ex"]},
               %{command: "mix test", path_globs: ["test/**/*.exs"]}
             ]
    end

    test "clear removes all rules for the selected project" do
      mock_project("demo")
      Settings.set_project("demo")
      settings = Settings.new()
      {:ok, project} = Store.get_project("demo")

      Settings.set_project_data(settings, "demo", %{
        "root" => project.source_root,
        "validation" => [
          %{"path_globs" => ["lib/**/*.ex"], "command" => "mix format"},
          %{"path_globs" => ["test/**/*.exs"], "command" => "mix test"}
        ]
      })

      assert :ok = Settings.Validation.clear()
      assert Settings.Validation.list() == []
      refute Settings.Validation.configured?()
    end
  end
end
