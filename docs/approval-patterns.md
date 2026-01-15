# Approval Patterns

Fnord requires approval for potentially dangerous operations. You can pre-approve specific commands using regex patterns to streamline your workflow.

## How Approvals Work

When fnord wants to perform certain operations, it prompts for approval:

```
fnord wants to run: git log --oneline -10
Approve? [y/n/always]:
```

**Options:**
- `y` - Approve once for this session
- `n` - Deny
- `always` - Add an approval pattern (prompts for scope)

## Automatic Approvals

### Built-in Read-Only Commands

These commands are automatically approved (no prompt):
- `git log`, `git show`, `git diff`, `git blame` (read-only git operations)
- `rg`, `grep` (when invoked by fnord's grep tool)
- Other read-only commands defined in fnord's source

### File Edits with --edit

When using `--edit` mode, you can auto-approve file operations:

```bash
fnord ask -p myproject --edit --yes -q "Add validation to the user model"
```

The `--yes` flag auto-approves file writes/edits. Shell commands still require approval.

## Shell tool path and local executable behavior

Fnord runs shell tool commands from the project root. For bare commands (no `/`), fnord resolves them only via `PATH`.

Project-local execution is only allowed when the command starts with `./` (for example `./make` or `./scripts/build`), and only if the resolved path stays within the project root (fail closed).

Commands like `scripts/foo` (without the leading `./`) are rejected; use `./scripts/foo` instead.

Approval patterns treat `./cmd` as distinct from `cmd` (you must explicitly include `./` in a prefix or regex to approve it).

**Examples:**
```bash
# Approving 'make check' does not approve './make check'
fnord config approve --project myproject --kind shell '^make check$'

# To approve './make check' explicitly:
fnord config approve --project myproject --kind shell '^\./make check$'
```

## Pre-Approval Patterns

You can pre-approve commands using regex patterns, either per-project or globally.

### Managing Approvals

```bash
# List current approvals
fnord config approvals --project myproject
fnord config approvals --global

# Add approval pattern
fnord config approve --project myproject --kind shell '<regex>'
fnord config approve --global --kind shell '<regex>'

# Remove approval pattern (edit settings.json manually)
```

### Approval Kinds

Currently supported:
- `shell` - Shell command patterns

### Pattern Examples

**Approve all npm commands:**
```bash
fnord config approve --project myproject --kind shell '^npm '
```

**Approve specific test commands:**
```bash
fnord config approve --project myproject --kind shell '^pytest tests/'
```

**Approve make targets:**
```bash
fnord config approve --project myproject --kind shell '^make (test|lint|check)'
```

**Approve safe git operations (example - these are already built-in):**
```bash
fnord config approve --global --kind shell '^git (status|log|show|diff)'
```

## Configuration Storage

Approvals are stored in `~/.fnord/settings.json`:

```json
{
  "projects": {
    "myproject": {
      "root": "/path/to/project",
      "approvals": {
        "shell": [
          "^npm test",
          "^pytest "
        ]
      }
    }
  },
  "approvals": {
    "shell": [
      "^make check"
    ]
  }
}
```

**Scopes:**
- Project-level: Under `projects.<name>.approvals`
- Global: Under top-level `approvals`

## Security Considerations

### Be Conservative

Pre-approving commands reduces security prompts but increases risk:

**Prompt injection:**
- If `FNORD.md` and `FNORD.local.md` are present in the project root, their contents are injected into every conversation, with the local file appended after the shared file
- Avoid including secrets or other sensitive information in that file

**Safe patterns:**
- Read-only operations (`git log`, `cat`, `grep`)
- Specific, bounded commands (`npm test`, `make check`)
- Commands in isolated directories

**Risky patterns:**
- Broad wildcards (`.+` matches everything)
- Commands that modify state (`rm`, `git push`, `npm publish`)
- Commands with user input (command injection risks)

### Pattern Safety Tips

1. **Use anchors** - Start with `^` to match from beginning
2. **Be specific** - Match exact commands, not broad patterns
3. **Avoid `.*`** - Too permissive, matches everything
4. **Test first** - Run commands manually before auto-approving

**Bad examples:**
```bash
# TOO BROAD - matches any command!
fnord config approve --global --kind shell '.*'

# DANGEROUS - auto-approves destructive commands
fnord config approve --project myproject --kind shell 'rm '

# RISKY - allows arbitrary git commands
fnord config approve --global --kind shell '^git '
```

**Good examples:**
```bash
# Specific test command
fnord config approve --project myproject --kind shell '^npm run test:unit$'

# Bounded to specific directory
fnord config approve --project myproject --kind shell '^pytest tests/unit/'

# Specific make target
fnord config approve --project myproject --kind shell '^make lint$'
```

## Regex Syntax

Patterns use standard regex syntax:

| Pattern | Meaning |
|---------|---------|
| `^` | Start of command |
| `$` | End of command |
| `.` | Any single character |
| `.*` | Zero or more characters |
| `\s` | Whitespace |
| `(a\|b)` | Match a or b |
| `[abc]` | Character class |
| `\` | Escape special chars |

**Examples:**

```bash
# Exact match
'^npm test$'

# Command with any args
'^npm test '

# Multiple commands
'^(npm test|npm run lint)'

# Path-specific
'^pytest tests/.*\.py$'
```

## Workflow Recommendations

### Interactive Approval (Default)

Best for:
- New projects you're exploring
- One-off questions
- When you're unsure what commands will run

**Workflow:**
1. Ask question without pre-approvals
2. Review each command prompt
3. Approve selectively
4. Use `always` to add patterns for frequently-needed commands

### Pre-Approved Workflow

Best for:
- Well-understood projects
- Repetitive tasks
- CI/CD-like operations
- Trusted environments

**Workflow:**
1. Identify safe, repetitive commands
2. Add targeted approval patterns
3. Use `--yes` for file operations in `--edit` mode
4. Review occasionally, remove stale patterns

### Hybrid Approach

Recommended for most users:
- Pre-approve safe read-only operations globally
- Pre-approve project-specific test/build commands
- Leave destructive operations to manual approval

**Example setup:**
```bash
# Global: safe read operations
fnord config approve --global --kind shell '^cat '
fnord config approve --global --kind shell '^ls '

# Project: test and lint
fnord config approve --project myproject --kind shell '^npm test'
fnord config approve --project myproject --kind shell '^make lint'

# Manual: anything else (rm, git push, npm publish, etc.)
```

## Troubleshooting

### Approval not matching

**Problem:** You added a pattern but still getting prompted

**Check:**
1. Pattern syntax - test regex with a regex tester
2. Scope - is pattern in right place (project vs global)?
3. Command exact match - check spacing, flags
4. Settings file syntax - ensure valid JSON

**Debug:**
```bash
# View current patterns
fnord config approvals --project myproject

# Check settings file directly
cat ~/.fnord/settings.json | jq '.projects.myproject.approvals'
```

### Too many approvals

**Problem:** Getting approval prompts for everything

**Cause:** No pre-approved patterns set up

**Solution:** Add patterns for your common workflows (see [Workflow Recommendations](#workflow-recommendations))

### Accidentally approved dangerous command

**Problem:** Used `always` on a risky command

**Solution:**
1. Edit `~/.fnord/settings.json`
2. Find and remove the pattern from `approvals.shell`
3. Save and restart fnord

## Advanced: Manual Configuration

Edit `~/.fnord/settings.json` directly for complex patterns:

```json
{
  "projects": {
    "myproject": {
      "root": "/path/to/project",
      "approvals": {
        "shell": [
          "^npm (test|run test:unit|run test:integration)",
          "^pytest tests/unit/.*",
          "^make (test|lint|check|build)"
        ]
      }
    }
  },
  "approvals": {
    "shell": [
      "^git (status|log|show|diff|blame)",
      "^rg ",
      "^cat [^/]",
      "^ls "
    ]
  }
}
```

**Editing tips:**
- Validate JSON after editing: `cat ~/.fnord/settings.json | jq .`
- One pattern per line in the array
- Use double backslashes for escaping in JSON: `"\\s"`, `"\\."`, etc.
- Test patterns before committing to config

## Further Reading

- [Main README](../README.md)
- [Advanced Asking Questions](asking-questions.md)
- [Writing Code](../README.md#writing-code)
