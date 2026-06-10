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
