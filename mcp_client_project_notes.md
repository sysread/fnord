# Milestone 1: MCP Client Support

## Implemented

- Added `{:hermes_mcp, "~> 0.14"}` to `mix.exs` to fetch and compile the Hermes MCP library.
- Refactored `lib/mcp/fnord_client.ex` to use `use Hermes.Client` with configured name, version, protocol, and capabilities, removing custom `start_link`, `list_tools`, and `call_tool` implementations.
- Updated `lib/mcp/transport.ex` to map server configs into Hermes transport tuples with keyword options and sensible defaults for missing keys.
- Replaced `lib/mcp/supervisor.ex` with a plain `Supervisor` that reads `Settings.MCP.effective_config/1` and starts child specs `{MCP.FnordClient, opts}` for each enabled server, introducing `MCP.Supervisor.instance_name/1` for naming.
- Added `lib/mcp/tools.ex` implementing `MCP.Tools.register_server_tools/2`, dynamically generating `AI.Tools.MCP.<Server>.<Tool>` modules via `Module.create/3` and wiring calls through `MCP.FnordClient.call_tool/4` with timeout handling.
- Introduced `lib/services/mcp.ex` (`Services.MCP`) to orchestrate startup: starts `MCP.Supervisor`, performs one-time discovery of server tools via `Services.Once`, and logs failures with JSON blobs.
- Integrated `Services.MCP.start/0` into `Services.start_config_dependent_services/0` so that MCP support initializes after CLI globals.
- Extended CLI command spec in `lib/cmd/config.ex` to include the `config mcp test` subcommand.
- Added the handler in `lib/cmd/config/mcp.ex` to run discovery, invoke `Services.MCP.test/0`, and print a structured JSON report without crashing on failures.

## Assumptions

- `Hermes.Client` macro provides child_spec and call functions accepting a named instance as the first argument.
- `Settings.MCP.effective_config/1` returns a map with `"enabled"` flag and server configs.
- JSON encoding (`Jason.encode!/2`) and `UI.warn/1` are available for error reporting.
- `Services.Once.run/2` ensures discovery runs exactly once per invocation.
- CLI options parsing and `Settings.set_project/1` correctly switch project context.

## Next Milestones

1. Implement `config mcp status` to provide live server connection and tool availability status.
2. Add WebSocket transport support with reconnect logic and heartbeat.
3. Enhance retry and circuit-breaker logic for transient failures in `MCP.FnordClient`.
4. Extend tool specification with richer JSON schemas and support for required/optional params.
5. Write comprehensive unit and integration tests for `MCP.Tools` and `Services.MCP` discovery.
6. Polish CLI UX: add progress indicators, clear error messages, and output formatting.
7. Optimize performance: batch transport updates, minimize supervisor restarts, and cache server info.
7. Optimize performance: batch transport updates, minimize supervisor restarts, and cache server info.

## 2025-08-29 Milestone 1 progress

- Added dependency `{:hermes_mcp, "~> 0.14"}` to `mix.exs`.
- Implemented `MCP.FnordClient` using `use Hermes.Client` with fnord identity, supporting multiple instances via `name` and `transport` options.
- Implemented `MCP.Transport` mapping config strings to Hermes transport tuples with keyword options.
- Implemented `MCP.Supervisor` to start a client per configured server using `Settings.MCP.effective_config/1`.
- Implemented `Services.MCP` orchestrator to start supervisor and perform one-time discovery using `Services.Once`.
- Implemented `MCP.Tools` to dynamically generate `AI.Tools` modules per discovered server tool.
- Wired `Services.MCP.start/0` into `Services.start_config_dependent_services/0`.
- Extended CLI with `fnord config mcp test` to validate MCP servers and show discovered tools.

Pending / Next steps:
- Verify Hermes.Client named instance API usage for `get_server_info/1`, `list_tools/1`, `call_tool/4` matches library expectations; adjust if necessary.
- Add tests for Services.MCP, MCP.Supervisor, and MCP.Tools (including a stub server).
- Improve error payloads with more precise Hermes error info and masks for secrets in headers/env.
- Optional: add status command and richer specs mapping.

## Milestone 1

- Removed unused attributes (`@default_timeout_ms` and `@max_timeout_ms`) from `Services.MCP` to eliminate warnings.
- Introduced wrapper functions `list_tools/1`, `get_server_info/1`, and `call_tool/4` in `MCP.FnordClient`, standardizing error normalization.
- Refactored `safe_list_tools/1` and `safe_get_info/1` in `Services.MCP` to use `client_mod/0` and the new wrappers for named instances.
- Added unit tests for `Services.MCP.test/0` in `test/services/mcp_test.exs` and dynamic tool modules in `test/mcp/tools_test.exs`

- Record:
  - Hermes call signature verification result
  - Attribute cleanup
  - Tests added and high-level behavior
  - Any refresh step needed for  AI.Tools  registry after module creation
