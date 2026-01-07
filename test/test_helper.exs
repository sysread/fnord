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

try do
  :meck.new(MCP.Supervisor, [:passthrough])
  :meck.expect(MCP.Supervisor, :start_link, fn _ -> {:ok, self()} end)
  :meck.expect(MCP.Supervisor, :instance_name, fn _ -> :mcp_supervisor end)
  :meck.new(Hermes.Client.Base, [:passthrough])
  :meck.expect(Hermes.Client.Base, :list_tools, fn _ -> [] end)
rescue
  _ -> :ok
catch
  _ -> :ok
end

# ------------------------------------------------------------------------------
# Require all elixir files in test/support
# ------------------------------------------------------------------------------
"test/support/**/*.ex"
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)
