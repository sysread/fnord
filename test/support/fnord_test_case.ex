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
      @moduletag capture_log: true

      import ExUnit.CaptureIO
      import Mox

      # ------------------------------------------------------------------------
      # Import utilities
      # ------------------------------------------------------------------------
      import Fnord.TestCase,
        only: [
          allow_service_mocks: 1,
          tmpdir: 0,
          capture_all: 1,
          mock_project: 1,
          mock_git_project: 1,
          mock_source_file: 3,
          git_ignore: 2,
          git_check_ignore!: 2,
          git_init!: 1,
          git_config_user!: 1,
          git_empty_commit!: 1,
          git_checkout_branch!: 2,
          git_checkout_detached!: 2,
          setup_git_repo!: 2,
          mock_conversation: 0,
          set_log_level: 1,
          set_config: 1,
          set_config: 2,
          safe_meck_new: 1,
          safe_meck_new: 2,
          safe_meck_unload: 1
        ]

      setup do
        # NOTE: Services.Globals is started in test_helper.exs
        Services.Globals.install_root()

        # Ensure quiet mode is enabled to prevent interactive prompts during
        # tests.
        Services.Globals.put_env(:fnord, :quiet, true)

        # Disable any sleep calls during HTTP retries to speed up tests.
        Services.Globals.put_env(:fnord, :http_retry_skip_sleep, true)

        :ok
      end

      # ------------------------------------------------------------------------
      # Override default implementations for services which use external APIs
      # or have other side effects.
      # ------------------------------------------------------------------------
      setup do
        Services.Globals.put_env(:fnord, :indexer, MockIndexer)
        :ok
      end

      # ------------------------------------------------------------------------
      # Setup Mox
      # ------------------------------------------------------------------------
      setup :verify_on_exit!
      setup :set_mox_from_context

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
        # Defensive cleanup: any prior test that mocked UI or GitCli via :meck
        # and crashed before unloading (or used :meck.expect on an un-:meck.new'd
        # module, which creates an implicit mock that never gets cleaned up)
        # would leak the mock to this test, breaking any UI/GitCli call path
        # and producing seed-dependent failures suite-wide. Force-unload before
        # each test so the leaker cannot poison the rest of the suite.
        Fnord.TestCase.safe_meck_unload(UI)
        Fnord.TestCase.safe_meck_unload(GitCli)

        Mox.stub_with(UI.Output.Mock, UI.Output.TestStub)
        Services.Globals.put_env(:fnord, :ui_output, UI.Output.Mock)
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
          # Just in case, ensure that the env var is overridden.
          Util.Env.put_env("HOME", tmp_dir)
          # Then, override app config.
          Services.Globals.put_env(:fnord, :test_home_override, tmp_dir)
          {:ok, home_dir: tmp_dir}
        end
      end

      # -----------------------------------------------------------------------------
      # Prevent logger output during tests
      # -----------------------------------------------------------------------------
      setup do
        orig = Logger.level()
        # suppress debug/info but allow warnings and errors
        Logger.configure(level: :warning)

        on_exit(fn ->
          Logger.configure(level: orig)
        end)

        :ok
      end

      # -----------------------------------------------------------------------------
      # Check out this test's app instance. The test process is already the
      # Globals root (installed in the first setup block), so the instance
      # and its services scope to this test and die with it. Config was
      # applied by the preceding setup blocks via put_env, so no :config is
      # passed here.
      # -----------------------------------------------------------------------------
      setup context do
        # Record async-ness for allow_service_mocks/1: Mox runs in private
        # mode for async tests (set_mox_from_context above), and Mox.allow
        # is only meaningful - and only legal - in private mode.
        Process.put(:fnord_test_async, Map.get(context, :async, false))

        {:ok, _} = Fnord.Instance.start_link()
        allow_service_mocks(self())

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

  # Mocks whose calls may execute inside service processes rather than the
  # test process (UI.Queue runs puts in its own GenServer, Approvals
  # dispatches impls, indexing happens in spawned workers).
  @service_facing_mocks [MockIndexer, MockApprovals, UI.Output.Mock]

  @doc """
  Grants the calling test's Mox stubs/expectations to every service process
  registered in the current tree. Async tests run Mox in private mode, where
  a mock called from a GenServer fails ownership - `$callers` covers Task
  processes, but GenServers carry only `$ancestors`, which Mox does not
  consult. No-op for sync tests (global mode, where Mox.allow is illegal).

  Called automatically after the instance boots. Call it again after starting
  a tree-scoped service ad hoc (`mock_conversation/0` does this for
  `Services.Task`); already-allowed pids are skipped.
  """
  @spec allow_service_mocks(pid()) :: :ok
  def allow_service_mocks(owner) do
    if Process.get(:fnord_test_async, false) do
      already = Process.get(:fnord_test_allowed_pids, MapSet.new())

      pids =
        Services.Instance.registered()
        |> Enum.map(&Services.Instance.whereis/1)
        |> Enum.filter(&is_pid/1)
        |> Enum.reject(&MapSet.member?(already, &1))

      for pid <- pids, mock <- @service_facing_mocks do
        Mox.allow(mock, owner, pid)
      end

      Process.put(
        :fnord_test_allowed_pids,
        Enum.into(pids, already)
      )
    end

    :ok
  end

  @doc """
  Safely creates a new meck mock for the given module. If the module is
  already mocked (from a previous test that didn't clean up properly), it is
  unloaded first. Prevents `:already_started` errors from meck collisions.
  """
  @spec safe_meck_new(module(), list()) :: :ok
  def safe_meck_new(module, opts \\ [:passthrough]) do
    safe_meck_unload(module)
    :meck.new(module, opts)
    :ok
  end

  @doc """
  Safely unloads a meck mock. Suppresses any errors from attempting to unload
  a module that wasn't mocked or was already unloaded.
  """
  @spec safe_meck_unload(module()) :: :ok
  def safe_meck_unload(module) do
    try do
      :meck.unload(module)
    catch
      _, _ -> :ok
    end

    :ok
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
    File.mkdir_p!(Path.dirname(path))
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
  Writes a `.gitignore` file with the given patterns and returns a `MapSet`
  of absolute paths under the repository that git reports as ignored.
  Excludes the `.git` directory.
  """
  def git_check_ignore!(project, patterns) do
    repo = project.source_root
    ignore_path = Path.join(repo, ".gitignore")
    File.write!(ignore_path, Enum.join(patterns, "\n"))

    candidates =
      repo
      |> Path.join("**/*")
      |> Path.wildcard(dot: true)
      |> Enum.reject(fn path ->
        String.starts_with?(path, Path.join(repo, ".git"))
      end)
      |> Enum.map(&Path.relative_to(&1, repo))

    args = ["check-ignore", "-v", "--"] ++ candidates

    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [_meta, path] -> [Path.expand(String.trim(path), repo)]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  @doc """
  Initializes a Git repository in the project's source root.
  """
  def git_init!(project) do
    repo = project.source_root
    System.cmd("git", ["init", "--quiet"], cd: repo)
    :ok
  end

  @doc """
  Configures Git user name and email for the project's source root.
  """
  def git_config_user!(project) do
    repo = project.source_root
    System.cmd("git", ["config", "user.name", "Fnord Prefect"], cd: repo)
    System.cmd("git", ["config", "user.email", "fnord@example.com"], cd: repo)
    :ok
  end

  @doc """
  Creates an empty Git commit in the project's source root.
  """
  def git_empty_commit!(project) do
    repo = project.source_root
    System.cmd("git", ["commit", "--allow-empty", "-m", "Initial commit", "--quiet"], cd: repo)
    :ok
  end

  @doc """
  Creates and checks out a new branch in the project's source root.
  """
  def git_checkout_branch!(project, branch) do
    repo = project.source_root
    System.cmd("git", ["checkout", "-b", branch, "--quiet"], cd: repo)
    :ok
  end

  @doc """
  Checks out a branch in detached HEAD mode in the project's source root.
  """
  def git_checkout_detached!(project, branch) do
    repo = project.source_root
    System.cmd("git", ["checkout", "--detach", branch, "--quiet"], cd: repo)
    :ok
  end

  @doc """
  Sets up a Git repository with an initial commit and branch in the project's source root.
  """
  def setup_git_repo!(project, branch) do
    git_init!(project)
    git_config_user!(project)
    git_empty_commit!(project)
    git_checkout_branch!(project, branch)
    :ok
  end

  @doc """
  Sets up a mock conversation service and task service. Assumes that
  `mock_project/1` has already been called to set up the project.
  """
  def mock_conversation() do
    # Start a conversation
    {:ok, conversation} =
      Store.Project.Conversation.new()
      |> Store.Project.Conversation.write()

    # Start the conversation service
    {:ok, conversation_pid} = Services.Conversation.start_link(conversation.id)

    # Store the current conversation PID in the global environment for access
    Services.Globals.put_env(:fnord, :current_conversation, conversation_pid)

    # Start the task service
    {:ok, task_pid} = Services.Task.start_link(conversation_pid: conversation_pid)

    # Async tests: the new service pids need Mox allowances like the roster.
    allow_service_mocks(self())

    %{
      conversation: conversation,
      conversation_pid: conversation_pid,
      task_pid: task_pid
    }
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
    Enum.each(config, fn {key, val} ->
      Services.Globals.put_env(:fnord, key, val)
    end)

    :ok
  end

  @doc """
  Sets a single config value for the test process. The value will be reset when
  the test process exits. All config is stored under the `:fnord` application
  environment.
  """
  def set_config(key, val) do
    Services.Globals.put_env(:fnord, key, val)
  end
end
