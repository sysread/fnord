# Advanced MCP Configuration

This guide covers advanced MCP server configuration options beyond what's available through the CLI.

## Quick Reference

For basic MCP setup, see the [main README](../README.md#mcp-servers).

## Command Reference

Complete reference for all MCP configuration commands.

### Listing Servers

```bash
# List project servers (default scope)
fnord config mcp list --project <project>

# List global servers
fnord config mcp list --global

# View effective configuration (merged global + project)
fnord config mcp list --effective
```

### Adding Servers

```bash
# Stdio transport
fnord config mcp add <name> --transport stdio --command <cmd> \
  [--arg <arg>] [--env KEY=VALUE] [--timeout-ms <ms>]

# HTTP transport
fnord config mcp add <name> --transport http --url <url> \
  [--header KEY=VALUE] [--timeout-ms <ms>]

# HTTP with OAuth
fnord config mcp add <name> --transport http --url <url> --oauth \
  [--client-id <id>] [--client-secret <secret>] [--scope <scope>]

# WebSocket transport
fnord config mcp add <name> --transport websocket --url <url> \
  [--header KEY=VALUE] [--timeout-ms <ms>]

# Add to global scope
fnord config mcp add <name> [...options...] --global
```

**Repeatable flags:**

- `--arg` - Can be specified multiple times for stdio args
- `--env` - Can be specified multiple times for environment variables
- `--header` - Can be specified multiple times for HTTP headers
- `--scope` - Can be specified multiple times for OAuth scopes

### Updating Servers

```bash
# Update server configuration
fnord config mcp update <name> [--transport ...] [--command ...] [--url ...] [...]

# Scope follows original (project or global)
# Use same flags as 'add' command
```

### Removing Servers

```bash
# Remove from project scope
fnord config mcp remove <name>

# Remove from global scope
fnord config mcp remove <name> --global
```

### Testing Connectivity

```bash
# Test all configured servers
fnord config mcp check

# Test specific project scope
fnord config mcp check --project <project>

# Test global scope
fnord config mcp check --global
```

Returns list of servers with their status and available tools.

### OAuth Commands

```bash
# Login to OAuth-enabled server (opens browser)
fnord config mcp login <server> [--timeout <ms>]

# Check token status
fnord config mcp status <server>
```

## Understanding Hermes Integration

Fnord uses [Hermes MCP](https://hexdocs.pm/hermes_mcp/) as its underlying MCP client library. Your fnord configuration maps directly to Hermes transport options, which means you can use any Hermes transport feature by editing your settings file directly.

**Configuration mapping:**

- Fnord stores configs in `~/.fnord/settings.json` (or project settings)
- `MCP.Transport` module converts these to Hermes transport tuples
- User-facing transport name: `"http"` → Hermes internal name: `:streamable_http`

## Additional Transport Options

The CLI exposes common options, but Hermes supports additional parameters for power users.

### StreamableHTTP Transport

Beyond `base_url` and `headers`, you can configure:

**Available options:**

- `mcp_path` (string) - Custom MCP endpoint path (default: "/mcp")
- `enable_sse` (boolean) - Enable Server-Sent Events for server-initiated messages (default: false)
- `transport_opts` (keyword list) - Underlying HTTP transport options
- `http_options` (keyword list) - HTTP client configuration options

**Example:**

```json
{
  "mcp_servers": {
    "myserver": {
      "transport": "http",
      "base_url": "https://api.example.com",
      "mcp_path": "/custom/mcp/endpoint",
      "enable_sse": true,
      "headers": {
        "X-Custom-Header": "value"
      }
    }
  }
}
```

**Reference:** [Hermes.Transport.StreamableHTTP](https://hexdocs.pm/hermes_mcp/Hermes.Transport.StreamableHTTP.html)

### STDIO Transport

Beyond `command`, `args`, and `env`, you can configure:

**Available options:**

- `cwd` (string) - Working directory for the server process

**Example:**

```json
{
  "mcp_servers": {
    "local-server": {
      "transport": "stdio",
      "command": "./my_server",
      "args": ["--verbose"],
      "cwd": "/path/to/server/directory",
      "env": {
        "API_KEY": "secret"
      }
    }
  }
}
```

**Reference:** [Hermes.Transport.STDIO](https://hexdocs.pm/hermes_mcp/Hermes.Transport.STDIO.html)

## Manual Configuration

For complete control, edit `~/.fnord/settings.json` directly:

### Global Configuration

```json
{
  "mcp_servers": {
    "server1": { /* config */ },
    "server2": { /* config */ }
  }
}
```

### Project-Specific Configuration

In `~/.fnord/settings.json`, under a project's settings:

```json
{
  "projects": {
    "myproject": {
      "root": "/path/to/project",
      "mcp_servers": {
        "project-server": { /* config */ }
      }
    }
  }
}
```

**Note:** Project-specific servers override global servers with the same name.

## Configuration Validation

Fnord validates your configuration when:

- Adding/updating servers via CLI
- Starting MCP operations (`fnord config mcp check`)

**Required fields:**

- **All transports:** `transport` (must be "stdio", "http", or "websocket")
- **stdio:** `command`
- **http/websocket:** `base_url`

**Optional fields:**

- `timeout_ms` - Request timeout in milliseconds
- `headers` - HTTP headers (http/websocket only)
- `oauth` - OAuth configuration (see [oauth-advanced.md](oauth-advanced.md))

## Transport Name Mapping

Fnord uses user-friendly transport names that map to Hermes atoms:

|User Config|Hermes Atom|Description|
|-------------|-------------|-------------|
|"stdio"|`:stdio`|Standard input/output|
|"http"|`:streamable_http`|HTTP with optional SSE|
|"websocket"|`:websocket`|WebSocket connection|

This abstraction allows fnord to:

- Use consistent, intuitive names in user-facing config
- Adapt to Hermes API changes without breaking user configs
- Add custom behavior (like OAuth header injection) at the transport boundary

## Troubleshooting

### Server not responding

Check connectivity:

```bash
fnord config mcp check
```

For HTTP servers, verify:

- `base_url` is correct and accessible
- Server is running and listening on specified port
- `mcp_path` matches server's endpoint (default: "/mcp")

For stdio servers, verify:

- `command` is in PATH or use absolute path
- Server process can be executed with provided `args`
- `cwd` exists (if specified)

### Headers not being sent

Headers are only used for HTTP and WebSocket transports. For stdio, use environment variables (`env`).

### OAuth headers

If you've configured OAuth, fnord automatically injects the `Authorization` header. Manual `Authorization` headers in your config will be overridden by OAuth tokens.

See [oauth-advanced.md](oauth-advanced.md) for OAuth troubleshooting.

## Further Reading

- [Hermes MCP Documentation](https://hexdocs.pm/hermes_mcp/)
- [Model Context Protocol Specification](https://spec.modelcontextprotocol.io/)
- [OAuth Advanced Configuration](oauth-advanced.md)
