ExUnit.start()

# ------------------------------------------------------------------------------
# Configure non-interactive mode for all tests
# ------------------------------------------------------------------------------
# Ensure quiet mode is enabled to prevent interactive prompts during tests
Application.put_env(:fnord, :quiet, true)

# ------------------------------------------------------------------------------
# Start applications for any external dependencies used in tests
# ------------------------------------------------------------------------------
Application.ensure_all_started(:briefly)
Application.ensure_all_started(:mox)

# ------------------------------------------------------------------------------
# Require all elixir files in test/support
# ------------------------------------------------------------------------------
"test/support/**/*.ex"
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)
