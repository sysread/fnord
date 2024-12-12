defmodule TestUtil do
  use ExUnit.CaseTemplate

  # ----------------------------------------------------------------------------
  # `use TestUtil` will import the `setup_args/1` macro.
  # ----------------------------------------------------------------------------
  using do
    quote do
      import TestUtil,
        only: [
          tmpdir: 0,
          mock_project: 1,
          mock_git_project: 1,
          mock_source_file: 3,
          git_ignore: 2,
          set_log_level: 1,
          set_config: 1
        ]
    end
  end

  # ----------------------------------------------------------------------------
  # Set up a temporary directory and override the HOME environment variable.
  # The store will create `$HOME/.fnord` to store settings and project data.
  # ----------------------------------------------------------------------------
  setup do
    # Save the original HOME environment variable and restore it on exit
    orig = System.get_env("HOME")
    on_exit(fn -> System.put_env("HOME", orig) end)

    # Create a temp dir to be our HOME directory
    {:ok, tmp_dir} = tmpdir()
    System.put_env("HOME", tmp_dir)

    {:ok, fnord_home: tmp_dir}
  end

  # -----------------------------------------------------------------------------
  # Prevent logger output during tests
  # -----------------------------------------------------------------------------
  setup do
    # Save the current log level
    orig = Logger.level()

    # Disable logging
    Logger.configure(level: :none)

    # Return the current log level to restore later
    on_exit(fn -> Logger.configure(level: orig) end)

    :ok
  end

  # -----------------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------------
  def tmpdir() do
    Briefly.create(directory: true)
  end

  def mock_project(name) do
    # Save the original fnord environment variable and restore it on exit
    orig = Application.get_all_env(:fnord)
    on_exit(fn -> Application.put_all_env(fnord: orig) end)
    Application.put_env(:fnord, :project, name)

    # Create a temp dir to be our source directory for the project
    {:ok, tmp_dir} = tmpdir()

    name
    |> Store.get_project()
    |> Store.Project.save_settings(tmp_dir, [])
  end

  def mock_git_project(name) do
    project = mock_project(name)
    repo = project.source_root

    git_env = [
      {"GIT_TRACE", "0"},
      {"GIT_CURL_VERBOSE", "0"},
      {"GIT_DEBUG", "0"}
    ]

    System.cmd("git", ["config", "--global", "init.defaultBranch", "main"],
      cd: repo,
      env: git_env
    )

    System.cmd("git", ["init"],
      cd: repo,
      env: git_env
    )

    project
  end

  def mock_source_file(project, name, content \\ "") do
    path = Path.join(project.source_root, name)
    File.write!(path, content)
    path
  end

  def git_ignore(project, patterns) do
    project.source_root
    |> Path.join(".gitignore")
    |> File.write!(Enum.join(patterns, "\n"))
  end

  def set_log_level(level \\ :none) do
    old_log_level = Logger.level()
    Logger.configure(level: level)
    on_exit(fn -> Logger.configure(level: old_log_level) end)
    :ok
  end

  def set_config(config) do
    orig = Application.get_all_env(:fnord)
    on_exit(fn -> Application.put_all_env(fnord: orig) end)

    Enum.each(config, fn {key, val} ->
      Application.put_env(:fnord, key, val)
    end)

    :ok
  end
end
