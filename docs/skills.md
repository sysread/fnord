# Skills

## Quick start

```bash
# Create a new project skill
fnord skills new --project myproject --skill example_skill

# Enable the skill
fnord skills enable --project myproject --skill example_skill

# List all skills
fnord skills list
```

Skills are reusable agent presets defined as TOML files.

A skill packages:

- a base system prompt
- a model preset
- toolset tags (which expand into `AI.Tools.with_*` toolboxes)
- an optional `response_format` for structured outputs

Skills are designed to be:

- easy to author (plain TOML)
- safe to run (RW gating and recursion limits)
- predictable (documented precedence and enablement semantics)

---

## Skill schema

A skill TOML file must define:

- `name` (string)
- `description` (string; brief)
- `model` (string; preset)
- `tools` (array of tool tags; must include `basic`, unknown tags are rejected)
- `system_prompt` (string)

Optional:

- `response_format` (table)

Example:

```toml
name = "web_research"
description = "Search the web and synthesize a concise answer with citations."
model = "web"
tools = ["basic", "web", "frobs"]
system_prompt = """
You are a research agent.
Prefer primary sources.
Cite URLs.
"""

[response_format]
type = "text"
```

---

## Skill locations

Fnord loads skill definitions from two locations:

1. **User skills**

   `~/fnord/skills/*.toml`

2. **Project skills**

   `~/.fnord/projects/<project>/skills/*.toml`

Project skills are loaded for the currently selected project. Many `fnord skills` subcommands accept `--project` to target a project without changing the selected project.

### Definition precedence (user overrides project)

If the same skill name is defined in both locations, the **user** skill
definition wins.

In `fnord skills list`, overridden definitions are shown using markdown
strikethrough.

---

## Enablement (Settings)

Enablement is controlled via `~/.fnord/settings.json`, not via TOML.

Keys:

- global: `skills: ["name", ...]`
- per-project: `projects.<project>.skills: ["name", ...]`

### Additive enablement (union semantics)

The effective set of enabled skills is the union of the global list and the
project list (when a project is selected). This matches frob enablement
semantics.

A skill enabled globally is available in every project. A skill enabled at the
project level is available only in that project, in addition to any globally
enabled skills.

---

## Model presets

Supported `model` values:

- `smart`
- `balanced`
- `fast`
- `web`
- `large_context`
- `large_context:<speed>` where speed is one of `smart|balanced|fast`

---

## Tool tags

Skill tool tags map onto tool groups:

- `basic` (required)
- `mcp`
- `frobs`
- `task`
- `coding`
- `web`
- `ui`
- `rw`
- `skills` (allows skill-to-skill calls)

Tool tags are strictly validated: unknown tags are errors.

---

## RW gating (`--edit`)

Skills that request the `rw` tool tag can only be executed when editing mode is
enabled (the user passed `--edit`).

Attempting to run an RW skill without `--edit` returns a denial error.

---

## Skill-to-skill calls and recursion depth

If a skill includes the `skills` tool tag, it can call other skills via the
`run_skill` tool.

To prevent runaway recursion, Fnord enforces a maximum nested skill depth.

Note: the depth budget is tracked globally (shared across concurrent skill invocations). This is a known v1 limitation.

---

## CLI usage

### List

```bash
fnord skills list
fnord skills list --project <project>
```

### Create / edit / remove

```bash
fnord skills new --project <project>
fnord skills edit --project <project> --skill <name>
fnord skills remove --project <project> --skill <name>
```

### Enable / disable

```bash
fnord skills enable --global --skill <name>
fnord skills enable --project <project> --skill <name>

fnord skills disable --global --skill <name>
fnord skills disable --project <project> --skill <name>
```

### Generate

`fnord skills generate` asks an LLM to draft a new skill definition and saves it to disk.

It uses the coordinator's `save_skill` tool under the hood, and saving requires an explicit confirmation prompt.

```bash
fnord skills generate --project <project> --description "Describe what you want this skill to do"

# Generate a user-global skill
fnord skills generate --global --description "..."

# Print enable/disable commands after generation
fnord skills generate --project <project> --description "..." --enable
```

---

## Tool usage (Coordinator)

Two coordinator-facing tools are provided:

- `run_skill` - run an enabled skill by name with an input prompt
- `save_skill` - save a new skill TOML into the current project's skills dir

`save_skill` requires explicit user confirmation.

---

## Troubleshooting / gotchas

- Shadowing: if the same skill name exists in both user and project locations, the user definition wins.
- Not enabled: `run_skill` only lists enabled skills. Use `fnord skills enable ...` if a skill is not showing up.
- RW gating: skills tagged with `rw` require running `fnord` with `--edit`.
