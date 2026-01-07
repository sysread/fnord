ExUnit.start()

# ------------------------------------------------------------------------------
# Start foundational services
# ------------------------------------------------------------------------------
Services.Globals.start_link()

case Services.Once.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# ------------------------------------------------------------------------------
# Start test applications
# ------------------------------------------------------------------------------
Application.ensure_all_started(:mox)
Application.ensure_all_started(:meck)

# ------------------------------------------------------------------------------
# Require all elixir files in test/support
# ------------------------------------------------------------------------------
"test/support/**/*.ex"
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)
