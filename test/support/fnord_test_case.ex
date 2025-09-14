defmodule Fnord.TestCase do
  @moduledoc """
  The default test case for Fnord. This module provides `Mox` configuration,
  conveniences for setting up tests, including creating temporary directories,
  mocking projects, and setting up the test environment.
  """

  use ExUnit.CaseTemplate

  import ExUnit.CaptureIO

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
  Mox.defmock(MockApprovals, for: Services.Approvals.Workflow)
  Mox.defmock(UI.Output.Mock, for: UI.Output)

  using do
    quote do
      import ExUnit.CaptureIO
      import Mox

      # ------------------------------------------------------------------------
      # Import utilities
      # ------------------------------------------------------------------------
      import Fnord.TestCase,
        only: [
          tmpdir: 0,
          capture_all: 1,
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
        # Ensure no OpenAI API key is set in the environment. This prevents
        # test from accidentally reaching out onto the network.
        System.put_env("OPENAI_API_KEY", "")
        System.put_env("FNORD_OPENAI_API_KEY", "")
        :ok
      end

      setup do
        # Silence git's default-branch advice during tests and prefer 'main'
        # These environment variables affect git subprocesses spawned by System.cmd/3
        System.put_env("GIT_CONFIG_COUNT", "2")
        System.put_env("GIT_CONFIG_KEY_0", "advice.defaultBranchName")
        System.put_env("GIT_CONFIG_VALUE_0", "false")
        System.put_env("GIT_CONFIG_KEY_1", "init.defaultBranch")
        System.put_env("GIT_CONFIG_VALUE_1", "main")

        on_exit(fn ->
          System.delete_env("GIT_CONFIG_COUNT")
          System.delete_env("GIT_CONFIG_KEY_0")
          System.delete_env("GIT_CONFIG_VALUE_0")
          System.delete_env("GIT_CONFIG_KEY_1")
          System.delete_env("GIT_CONFIG_VALUE_1")
        end)

        :ok
      end

      setup do
        # Globally override interactive mode, so that code called by tests does
        # not attempt to read from stdin.
        Settings.set_quiet(true)
        :ok
      end

      setup do
        # Globally override the configured Indexer with our stub because the
        # Indexer uses an external service to generate embeddings and
        # AI-generated summaries and so whatnot.
        Mox.stub_with(MockIndexer, StubIndexer)
        set_config(:indexer, MockIndexer)
      end

      setup do
        Mox.stub_with(MockApprovals, StubApprovals)

        set_config(:approvals, %{
          edit: MockApprovals,
          shell: MockApprovals
        })
      end

      setup do
        Mox.stub_with(UI.Output.Mock, UI.Output.TestStub)
        Application.put_env(:fnord, :ui_output, UI.Output.Mock)
      end

      setup do
        # Instruct Services.NamePool to always return the default name.
        set_config(:nomenclater, :fake)
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

          Settings.new() |> Settings.set(:approvals, %{})

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

      # -----------------------------------------------------------------------------
      # Start internal services
      # -----------------------------------------------------------------------------
      setup do
        Services.start_all()
        Services.start_config_dependent_services()
        :ok
      end

      # -----------------------------------------------------------------------------
      # Ensure project root override is cleared before and after each test
      # -----------------------------------------------------------------------------
      setup do
        Settings.set_project_root_override(nil)
        on_exit(fn -> Settings.set_project_root_override(nil) end)
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
  Runs `fun` once and returns `{stdout, stderr}`.
  """
  @spec capture_all((-> any)) :: {binary, binary}
  def capture_all(fun) do
    capture_io(:stderr, fn ->
      stdout = capture_io(fn -> fun.() end)
      Process.put({__MODULE__, :stdout}, stdout)
    end)
    |> then(fn stderr ->
      stdout = Process.delete({__MODULE__, :stdout})
      {stdout, stderr}
    end)
  end

  @doc """
  Creates a new project *directory* for the given project name. The project's
  settings are created in the store, but the empty temp dir is NOT indexed.
  """
  def mock_project(name) do
    set_config(:project, name)

    # Create a temp dir to be our source directory for the project
    {:ok, tmp_dir} = tmpdir()
    {:ok, project} = Store.get_project(name)

    Store.Project.save_settings(project, tmp_dir, [])
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
