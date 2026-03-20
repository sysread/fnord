defmodule Cmd.Config.ValidationTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureLog

  setup do
    File.rm_rf!(Settings.settings_file())
    :ok
  end

  setup do
    old_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: old_level) end)
    :ok
  end

  describe "validation list" do
    test "lists current project validation rules with displayed indexes" do
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

      {output, _stderr} = capture_all(fn -> Cmd.Config.run(%{}, [:validation, :list], []) end)

      assert {:ok,
              [
                %{"index" => 1, "command" => "mix format", "path_globs" => ["lib/**/*.ex"]},
                %{"index" => 2, "command" => "mix test", "path_globs" => ["test/**/*.exs"]}
              ]} = SafeJson.decode(output)
    end

    test "accepts --project to inspect another project" do
      mock_project("alpha")
      mock_project("beta")
      Settings.set_project("alpha")
      settings = Settings.new()
      {:ok, project} = Store.get_project("beta")

      Settings.set_project_data(settings, "beta", %{
        "root" => project.source_root,
        "validation" => [
          %{"path_globs" => ["docs/**/*.md"], "command" => "markdownlint-cli2 docs/**/*.md"}
        ]
      })

      {output, _stderr} =
        capture_all(fn -> Cmd.Config.run(%{project: "beta"}, [:validation, :list], []) end)

      assert {:ok,
              [
                %{
                  "index" => 1,
                  "command" => "markdownlint-cli2 docs/**/*.md",
                  "path_globs" => ["docs/**/*.md"]
                }
              ]} = SafeJson.decode(output)
    end

    test "errors cleanly without project context" do
      log = capture_log(fn -> Cmd.Config.run(%{}, [:validation, :list], []) end)
      assert log =~ "Project not specified or not found"
    end
  end

  describe "validation add" do
    test "requires one command positional arg" do
      mock_project("demo")
      Settings.set_project("demo")

      log =
        capture_log(fn ->
          Cmd.Config.run(%{path_glob: ["lib/**/*.ex"]}, [:validation, :add], [])
        end)

      assert log =~ "Command is required"
    end

    test "succeeds without --path-glob and stores project-root sentinel" do
      mock_project("demo")
      Settings.set_project("demo")

      {output, _stderr} =
        capture_all(fn -> Cmd.Config.run(%{}, [:validation, :add], ["mix format"]) end)

      assert {:ok,
              [
                %{
                  "index" => 1,
                  "command" => "mix format",
                  "path_globs" => ["."]
                }
              ]} = SafeJson.decode(output)
    end

    test "stores normalized command text and path globs" do
      mock_project("demo")
      Settings.set_project("demo")

      {output, _stderr} =
        capture_all(fn ->
          Cmd.Config.run(
            %{path_glob: [" lib/**/*.ex ", " test/**/*.exs "]},
            [:validation, :add],
            ["  mix format  "]
          )
        end)

      assert {:ok,
              [
                %{
                  "index" => 1,
                  "command" => "mix format",
                  "path_globs" => ["lib/**/*.ex", "test/**/*.exs"]
                }
              ]} = SafeJson.decode(output)
    end
  end

  describe "validation remove" do
    test "removes a rule by displayed index" do
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

      {output, _stderr} =
        capture_all(fn -> Cmd.Config.run(%{}, [:validation, :remove], ["1"]) end)

      assert {:ok,
              [
                %{"index" => 1, "command" => "mix test", "path_globs" => ["test/**/*.exs"]}
              ]} = SafeJson.decode(output)
    end
  end

  describe "validation clear" do
    test "removes all rules for the project" do
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

      {output, _stderr} = capture_all(fn -> Cmd.Config.run(%{}, [:validation, :clear], []) end)

      assert {:ok, []} = SafeJson.decode(output)
    end
  end
end
