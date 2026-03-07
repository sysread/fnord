# Skills

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
- `tools` (array of tool tags)
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

### Project override semantics

If a project is selected and the project's `skills` key is present, it is the
authoritative enabled set (even if empty).

Otherwise, the global enabled list is used.

This differs intentionally from frob enablement, which unions global+project.

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
- `frobs`
- `task`
- `coding`
- `web`
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
fnord skills enable --scope global  --skill <name>
fnord skills enable --scope project --project <project> --skill <name>

fnord skills disable --scope global  --skill <name>
fnord skills disable --scope project --project <project> --skill <name>
```

---

## Tool usage (Coordinator)

Two coordinator-facing tools are provided:

- `run_skill` — run an enabled skill by name with an input prompt
- `save_skill` — save a new skill TOML into the current project's skills dir

`save_skill` requires explicit user confirmation.
