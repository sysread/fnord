defmodule Fnord.TestCase do
  @moduledoc """
  The default test case for Fnord. This module provides `Mox` configuration,
  conveniences for setting up tests, including creating temporary directories,
  mocking projects, and setting up the test environment.
  """

  use ExUnit.CaseTemplate

  # ----------------------------------------------------------------------------
  # Define and configure mocks
  #
  # Any mocks which should be defaulted globally for tests should:
  # 1. Be declared here
  # 2. Include a stub implementation in `tests/support`
  # 3. Be configured with `Mox.stub_with` in a setup block below
  # 4. Have their configured implementation overridden in tests as needed OR
  #    globally in a setup block below
  # ----------------------------------------------------------------------------
  Mox.defmock(MockIndexer, for: Indexer)

  using do
    quote do
      import Mox

      # ------------------------------------------------------------------------
      # Import utilities
      # ------------------------------------------------------------------------
      import Fnord.TestCase,
        only: [
          tmpdir: 0,
          mock_project: 1,
          mock_git_project: 1,
          mock_source_file: 3,
          git_ignore: 2,
          set_log_level: 1,
          set_config: 1,
          set_config: 2
        ]

      # ------------------------------------------------------------------------
      # Set up Mox
      # ------------------------------------------------------------------------
      setup :verify_on_exit!
      setup :set_mox_from_context

      setup do
        # Globally override the configured Indexer with our stub because the
        # Indexer uses an external service to generate embeddings and
        # AI-generated summaries and so whatnot.
        set_config(:indexer, MockIndexer)
        Mox.stub_with(MockIndexer, StubIndexer)

        :ok
      end

      # -------------------------------------------------------------------------
      # Ensure all temp dirs created by this test process are cleaned up when
      # the process exits.
      # -------------------------------------------------------------------------
      setup do
        on_exit(&Briefly.cleanup/0)
        :ok
      end

      # ----------------------------------------------------------------------------
      # Set up a temporary directory and override the HOME environment variable.
      # The store will create `$HOME/.fnord` to store settings and project data.
      # ----------------------------------------------------------------------------
      setup do
        with {:ok, tmp_dir} <- tmpdir() do
          orig = System.get_env("HOME")
          on_exit(fn -> System.put_env("HOME", orig) end)
          System.put_env("HOME", tmp_dir)
          {:ok, home_dir: tmp_dir}
        end
      end

      # -----------------------------------------------------------------------------
      # Prevent logger output during tests
      # -----------------------------------------------------------------------------
      setup do
        orig = Logger.level()
        Logger.configure(level: :none)
        on_exit(fn -> Logger.configure(level: orig) end)
        :ok
      end
    end
  end

  # -----------------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------------
  @doc """
  Returns an `:ok` tuple with a temporary directory path. The directory will be
  deleted when the test process exits.
  """
  def tmpdir() do
    Briefly.create(directory: true)
  end

  @doc """
  Creates a new project *directory* for the given project name. The project's
  settings are created in the store, but the empty temp dir is NOT indexed.
  """
  def mock_project(name) do
    set_config(:project, name)

    # Create a temp dir to be our source directory for the project
    {:ok, tmp_dir} = tmpdir()

    name
    |> Store.get_project()
    |> Store.Project.save_settings(tmp_dir, [])
  end

  @doc """
  Creates a new project with `mock_project`, and then initializes the project's
  root directory as a git repository with NO commits.
  """
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

  @doc """
  Creates a new file in the project's source directory with the given content.
  """
  def mock_source_file(project, name, content \\ "") do
    path = Path.join(project.source_root, name)
    File.write!(path, content)
    path
  end

  @doc """
  Creates a `.gitignore` file in the project's source directory with the given
  patterns. Note that this should be used with `mock_git_project` to ensure the
  `.gitignore` file is relevant.
  """
  def git_ignore(project, patterns) do
    project.source_root
    |> Path.join(".gitignore")
    |> File.write!(Enum.join(patterns, "\n"))
  end

  @doc """
  Sets the log level for the test process. The log level will be reset when the
  test process exits.
  """
  def set_log_level(level \\ :none) do
    old_log_level = Logger.level()
    Logger.configure(level: level)
    on_exit(fn -> Logger.configure(level: old_log_level) end)
    :ok
  end

  @doc """
  Sets the configuration for the test process. The configuration will be reset
  when the test process exits. Accepts a list of key-value pairs. All config is
  stored under the `:fnord` application environment.
  """
  def set_config(config) do
    orig = Application.get_all_env(:fnord)
    on_exit(fn -> Application.put_all_env(fnord: orig) end)

    Enum.each(config, fn {key, val} ->
      Application.put_env(:fnord, key, val)
    end)

    :ok
  end

  @doc """
  Sets a single config value for the test process. The value will be reset when
  the test process exits. All config is stored under the `:fnord` application
  environment.
  """
  def set_config(key, val) do
    orig = Application.get_env(:fnord, key)
    on_exit(fn -> Application.put_env(:fnord, key, orig) end)
    Application.put_env(:fnord, key, val)
  end
end
