# AI tool integrations

Fnord is often used alongside other AI coding tools (Cursor, Claude
Code, agents authored against the Agent Skills spec, etc.). This
document covers every way fnord is aware of or consumes files authored
for those other tools: what fnord will load, when, where from, under
what settings, and what commands surface them.

Short version: fnord's awareness of other-tool files falls into three
tiers, in order of reliability:

1. **Always-loaded** - `FNORD.md` / `FNORD.local.md`. Native to fnord.
   Read every session when present. No toggle.
2. **Opt-in loaded** - the `external_configs` framework. Toggle per
   project; when enabled, fnord discovers and catalogs files from
   Cursor / Claude Code conventions at session start.
3. **Research-discovered** - coordinator and sub-agent prompts instruct
   the model to look for convention files (`README.md`, `CLAUDE.md`,
   `AGENTS.md`, `CONTRIBUTING.md`) when a task demands project context.
   Not pre-loaded; the agent reads them on demand via
   `file_contents_tool`.

The first two are guaranteed (if toggled on). The third is
best-effort: whether and when the agent reads a given file depends on
what the task needs.

## Tier 1: Always-loaded native prompts

### FNORD.md and FNORD.local.md

Checked for in the project source root. Read by
`Store.Project.project_prompt/1` at every session start and injected as a
system message:

- `FNORD.md` - shared project instructions. Commit to version control.
- `FNORD.local.md` - local user instructions. Add to `.gitignore`.

When both exist, local instructions take priority if they conflict.

No toggle; these are always read when present. Put fnord-authoritative
project instructions here for guaranteed injection.

## Tier 2: Opt-in loaded (external_configs)

The `external_configs` framework parses and injects files authored for
other AI coding tools' conventions. Off by default, enabled per
project via CLI.

### Quick start

```bash
# See what's enabled for the current project
fnord config external-configs list

# Enable Cursor rules
fnord config external-configs enable cursor:rules

# Enable Claude Code subagents
fnord config external-configs enable claude:agents

# Disable a source
fnord config external-configs disable cursor:skills
```

At `fnord ask` start, if files exist on disk for a disabled source,
fnord emits a yellow warning with the exact command to enable it
(command highlighted in green).

### Sources

| Source          | Global path                     | Project path                              | Format                                |
|-----------------|---------------------------------|-------------------------------------------|---------------------------------------|
| `cursor:rules`  | `~/.cursor/rules/**/*.mdc`      | `.cursor/rules/**/*.mdc`, `.cursorrules`  | `.mdc` w/ YAML frontmatter            |
| `cursor:skills` | `~/.cursor/skills/*/SKILL.md`   | `.cursor/skills/*/SKILL.md`               | dir + SKILL.md (Agent Skills spec)    |
| `claude:skills` | `~/.claude/skills/*/SKILL.md`   | `.claude/skills/*/SKILL.md`               | dir + SKILL.md (Agent Skills spec)    |
| `claude:agents` | `~/.claude/agents/*.md`         | `.claude/agents/*.md`                     | single `.md` w/ YAML frontmatter      |

When the same name exists at both scopes, the project entry wins
(CSS-style override). Global entries cover the rest.

### Cursor rules

Each `.mdc` file is classified into one of four modes by frontmatter:

- **alwaysApply** (`alwaysApply: true`) - injected into every session.
- **auto-attached** (`globs: <pattern>`) - injected when a file matching
  the glob is read or written by a tool during the session. Fires once
  per (rule, file) pair per session.
- **agent-requested** (description set, no globs) - listed in the
  catalog with the description only; the model reads the body on
  demand.
- **manual** (none of the above) - listed, not auto-injected; readable
  on demand.

Legacy `.cursorrules` at the project root is treated as a single
always-apply rule.

**Debugging**: set `FNORD_DEBUG_CURSOR_RULES=1` to have fnord emit
`UI.debug` lines describing every cursor-rule decision: always-apply
rule bodies injected at bootstrap, the catalog listing of
non-always rules, each auto-attach check against a file path (matches
and misses), every successful auto-attach injection, and Once-gated
skips. Useful for figuring out why a rule did or didn't fire for a
given file.

### Cursor skills and Claude Code skills

Both follow the [Agent Skills](https://github.com/anthropics/agent-skills)
spec: one directory per skill containing `SKILL.md` with YAML
frontmatter (`name`, `description`, optional `when_to_use`) and
optional support files.

Fnord surfaces name + description (+ `when_to_use`) and the absolute
path to the `SKILL.md`. When a task matches a skill's description, the
model reads the file with `file_contents_tool` and follows the
guidance.

### Claude Code subagents

Single `.md` file per agent. YAML frontmatter defines `name`,
`description`, `tools`, optional `model`; body is the system prompt
that agent would run with.

Fnord surfaces agents the same way as skills. When a task matches an
agent's description, the model reads the file and internalizes the
role for that turn.

**Edit-mode gating**: an agent whose `tools:` list contains `Write` or
`Edit` needs capabilities fnord exposes only in edit mode. Without
`-e`, these agents are hidden from the catalog and a count note tells
the model how many were omitted.

### What gets injected and when

At every `fnord ask` session start, for each enabled source:

1. Boot listings (`UI.info` lines): `Cursor skills:`, `Claude skills:`,
   `Claude agents:` print the name list for whatever's loaded.
2. A single system message is built from all enabled sources and
   prepended to the coordinator's prompt. It lists each entry with its
   description (truncated) and, for external skills/agents, the
   absolute path so the model can read the body.
3. Cursor rules with `alwaysApply: true` get their full body injected
   as separate system messages.
4. Auto-attached rules fire later, on matching file reads **and**
   writes. This happens regardless of whether `--edit` is set: the
   Injector hooks both `file_contents_tool` (read) and `file_edit_tool`
   (write), and it fires once per `(rule, file)` pair per session. Only
   Claude subagents have edit-mode gating (via their `tools:` list);
   cursor rules do not.

All catalog messages are system-role and are stripped when the
conversation is saved. They re-inject on every session start.

### Sub-agent visibility

Fnord's code phases (`TaskPlanner`, `TaskImplementor`, `TaskValidator`)
and the `research_tool` build their own fresh message lists rather than
reading from `Services.Conversation`. Those sub-agents explicitly
inherit the catalog at construction via
`ExternalConfigs.Catalog.system_messages/0`: they see the same skills
catalog, cursor rules listing, and always-apply rule bodies the
coordinator saw at its own bootstrap.

What sub-agents do NOT inherit: mid-stream auto-attach injections
triggered by the parent session. Those get appended to the parent's
`Services.Conversation`, which sub-agents don't consume. If a sub-agent
reads a file that matches an auto-attached rule during its own work,
the Once gate (keyed globally on `(rule, path)`) will suppress
re-firing; the rule body can still be read on demand via
`file_contents_tool` using the path surfaced in the catalog listing.

### settings.json layout

```json
{
  "projects": {
    "myproject": {
      "root": "/path/to/project",
      "external_configs": {
        "cursor:rules": true,
        "cursor:skills": false,
        "claude:skills": true,
        "claude:agents": true
      }
    }
  }
}
```

Missing keys are treated as `false`. Hand-edits work; the CLI is the
preferred interface.

## Tier 3: Research-discovered (agent-prompted)

The coordinator and several sub-agents are instructed (in their
prompts) to look for convention files when researching a project.
These are **not pre-loaded** - the agent reads them on demand when the
task needs context.

| Prompt location                         | Files the agent is told to check                                  | When it runs                        |
|-----------------------------------------|-------------------------------------------------------------------|-------------------------------------|
| `lib/ai/agent/code/common.ex`           | READMEs, CONTRIBUTING, `AGENTS.md`, `CLAUDE.md`                   | shared by code-modifying sub-agents |
| `lib/ai/agent/code/task_planner.ex`     | `README.md`, `CLAUDE.md`, `AGENTS.md`                             | edit-mode planning phase            |
| `lib/ai/agent/code/task_implementor.ex` | `README.md`, `CLAUDE.md`, `AGENTS.md`                             | edit-mode implementation phase      |
| `lib/ai/agent/code/task_validator.ex`   | `README.md`, `CLAUDE.md`, `AGENTS.md`                             | edit-mode validation phase          |
| `lib/ai/agent/review/pedantic.ex`       | `FNORD.md` or equivalent project guidelines                       | `/check-my-work` review pipeline    |
| `lib/cmd/prime.ex`                      | `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/`, `AGENTS.md` | `fnord prime`                       |

Practical implication: **fnord will read your `CLAUDE.md` or
`AGENTS.md` if the session's task needs project context, but it isn't
guaranteed like `FNORD.md` is.** Put fnord-authoritative instructions
in `FNORD.md` for guaranteed injection; put shared-across-tools
guidance in the convention files and trust the agent to find them.

## Order of consultation in a typical `fnord ask` session

1. Coordinator bootstrap builds system messages:
   - New-session notice
   - Initial agent prompt + name
   - Memories and notes
   - **`FNORD.md` + `FNORD.local.md`** (if present)
   - **External configs catalog** (enabled sources)
   - **`alwaysApply` cursor rule bodies**
   - Worktree context
2. Boot-line log: frobs, MCP tools, fnord skills, external skills/agents.
3. Disabled-but-present warnings (one per disabled source with files).
4. Session begins. During tool calls:
   - `file_contents_tool` / `file_edit_tool` may trigger auto-attached
     cursor rule injection for matching paths.
   - Sub-agents (planner, implementor, validator, review) may read
     `CLAUDE.md` / `AGENTS.md` / `README.md` per their own prompt
     guidance.
5. On `fnord prime`, the agent explicitly consults the prime list
   (README, CLAUDE.md, CONTRIBUTING, docs/, AGENTS.md).

## Commands that interact with these

- `fnord config external-configs list|enable|disable SOURCE [--project NAME]`
  - Manage the tier-2 opt-in toggles.
- `fnord ask`
  - Loads tier 1 + enabled tier 2. Research-phase sub-agents may reach
    into tier 3.
- `fnord ask --edit` (or `-e`)
  - Same as above, plus unlocks Claude subagents whose `tools` include
    `Write`/`Edit` and runs the code-phase sub-agents (task_planner
    etc.) that hit tier 3.
- `fnord prime`
  - Explicitly asks the agent to research the project docs including
    `CLAUDE.md` and `AGENTS.md`.

## What fnord does NOT consume automatically

Even when present in your repo, these are not loaded by fnord's
config-loader path (they may still be read during agent research per
tier 3 if the prompts mention them):

- `.github/copilot-instructions.md` (GitHub Copilot) - never read.
- `.cursor/docs/*` - never read.
- Cursor's UI-stored global rules (live in the IDE's settings, not on
  disk under `~/.cursor/rules/`) - never read.

For shared "both tools should read this" instructions, the reliable
path is `FNORD.md` (guaranteed injection) plus your other tool's
preferred location (Claude sees `CLAUDE.md`, Cursor sees
`.cursor/rules/`, etc.).
