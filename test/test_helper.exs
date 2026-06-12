ExUnit.start()

# ------------------------------------------------------------------------------
# Start foundational services
# ------------------------------------------------------------------------------
Services.Globals.start_link()

# Services are tree-scoped (see Services.Instance) and boot per-test via
# Fnord.Instance in Fnord.TestCase setup; a suite-global instance here would
# be unreachable from test process trees and would mask leaks.

# ------------------------------------------------------------------------------
# Start test applications
# ------------------------------------------------------------------------------
Application.ensure_all_started(:mox)

# ------------------------------------------------------------------------------
# Static test environment (VM-wide, never restored)
#
# Every test wants the same values, so they are set once here rather than
# per-test in Fnord.TestCase: System env is VM-global, and a per-test on_exit
# delete would yank a value out from under a concurrently running async test.
# ------------------------------------------------------------------------------
# Clear OpenAI API keys so completion-path tests that forget to mock can't
# silently reach the live API. Embeddings are local, so this only guards
# completions.
System.put_env("OPENAI_API_KEY", "")
System.put_env("FNORD_OPENAI_API_KEY", "")

# Disable lowfat output-filtering so cmd_tool tests observe raw command output
# regardless of whether `lowfat` is installed on this machine. The dedicated
# lowfat test opts back in (and restores this default when done).
System.put_env("FNORD_NO_LOWFAT", "1")

# Point HOME at a suite-lifetime temp dir so subprocesses (git reads
# $HOME/.gitconfig) and any stray env-HOME reader can never touch the
# developer's real home. Per-test isolation of the fnord store comes from the
# :test_home_override Globals key set in Fnord.TestCase; this is the
# deterministic floor beneath it. Plain mkdir rather than Briefly: Briefly
# ties cleanup to the calling process, and this dir must outlive the suite.
suite_home = Path.join(System.tmp_dir!(), "fnord-test-home-#{System.unique_integer([:positive])}")
File.mkdir_p!(suite_home)
System.put_env("HOME", suite_home)

# Silence git's default-branch advice and prefer 'main' in git subprocesses.
System.put_env("GIT_CONFIG_COUNT", "2")
System.put_env("GIT_CONFIG_KEY_0", "advice.defaultBranchName")
System.put_env("GIT_CONFIG_VALUE_0", "false")
System.put_env("GIT_CONFIG_KEY_1", "init.defaultBranch")
System.put_env("GIT_CONFIG_VALUE_1", "main")

# ------------------------------------------------------------------------------
# Require all elixir files in test/support
# ------------------------------------------------------------------------------
"test/support/**/*.ex"
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)
