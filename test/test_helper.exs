ExUnit.start()

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
