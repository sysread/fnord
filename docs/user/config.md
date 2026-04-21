# Configuration Reference

Fnord stores configuration in `~/.fnord/settings.json`.
The `config` command manages global and project settings, approval patterns, validation rules, and MCP servers.

Commands operate on the currently selected project by default. Some project-scoped commands also accept `--project` to target a different project explicitly.

## Project selection

```bash
fnord config set --project myproject
fnord config set --project myproject --root /path/to/project
```

`config set` selects a project and optionally sets its root directory.
The `--project` flag is required.
The project must already exist in fnord's store, typically because you indexed it earlier or selected it in a previous session.

### Options

- `--project / -p NAME` - project name (required)
- `--root / -r PATH` - project root directory
- `--exclude / -x PATTERN` - glob pattern to exclude from indexing (repeatable)

## Listing configuration

```bash
fnord config list
```

Shows the current approval settings together with the selected project's stored configuration as JSON.

## Approval patterns

See [Approval Patterns](approval-patterns.md) for the full guide.

```bash
fnord config approve --kind shell --global "mix"
fnord config approve --kind shell_full "git status"
fnord config approvals
fnord config approvals --global
```

## Validation rules

See [Validation Rules](validation-rules.md) for the full guide.

```bash
fnord config validation list
fnord config validation add "make check" --path-glob "lib/**/*.ex"
fnord config validation remove 1
fnord config validation clear
```

## External configs (Cursor and Claude Code)

See [AI Tool Integrations](ai-tool-integrations.md) and [Skills](skills.md) for the full guide.

Toggle per-project discovery of Cursor rules, Cursor skills, Claude Code skills, and Claude Code subagents.
All four sources default to disabled; enabling any source opts the selected project into discovery of the matching files from both the user's home directory and the project source root.

```bash
fnord config external-configs list
fnord config external-configs enable --source cursor:rules
fnord config external-configs enable --source cursor:skills
fnord config external-configs enable --source claude:skills
fnord config external-configs enable --source claude:agents
fnord config external-configs disable --source cursor:rules
```

Sources: `cursor:rules`, `cursor:skills`, `claude:skills`, `claude:agents`.

## MCP servers

See [Advanced MCP Configuration](mcp-advanced.md) for the full guide.

```bash
fnord config mcp list
fnord config mcp list --global
fnord config mcp list --effective
fnord config mcp add myserver --transport stdio --command /path/to/server
fnord config mcp update myserver --timeout-ms 30000
fnord config mcp remove myserver
fnord config mcp check
fnord config mcp login myserver
fnord config mcp status myserver
```

Use [Advanced MCP Configuration](mcp-advanced.md) for transport-specific flags such as headers, env vars, OAuth options, and timeouts.

## Settings structure

Settings are scoped:

- **Global** - approval patterns, frobs, skills, MCP servers shared across all projects
- **Per-project** - root directory, exclude patterns, project-specific approvals, frobs, skills, MCP servers, validation rules

Per-project settings are stored under `projects.<name>` in settings.json.
The selected project is stored as the top-level `project` key.
