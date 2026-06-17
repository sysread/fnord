# Use fnord with Claude Code and Cursor

## What this covers

Running fnord alongside other AI coding tools and knowing which of your
existing instruction files it will actually honor — and how reliably.
fnord is aware of three tiers of files; this use case is about choosing
the right tier for a given instruction so it lands when you expect it to.

## When to use it

- You already have `CLAUDE.md`, `.cursor/rules/`, or Agent Skills and want
  fnord to respect them.
- An instruction you wrote for Claude or Cursor isn't affecting fnord.
- You're deciding where shared, cross-tool guidance should live.

## The three tiers (most to least reliable)

| Tier | Files | Loaded | Reliability |
| --- | --- | --- | --- |
| 1. Always-loaded | `FNORD.md`, `FNORD.local.md` | Every session, no toggle | Guaranteed |
| 2. Opt-in | Cursor rules, Cursor/Claude skills, Claude subagents | When the `external_configs` source is enabled | Guaranteed if toggled on |
| 3. Research-discovered | `README.md`, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md` | On demand, if the task needs context | Best-effort |

The rule of thumb: **the more guaranteed you need an instruction to be,
the lower the tier number it belongs in.** `FNORD.md` is the only thing
fnord promises to inject every time.

## Steps

1. Decide what the instruction is for:
   - Must apply on every fnord session → put it in `FNORD.md` (tier 1).
     See [Project instructions and local overrides](project-instructions-and-local-overrides.md).
   - Tool-specific behavior you want fnord to opt into → tier 2.
   - Shared cross-tool orientation you're fine with fnord discovering when
     relevant → tier 3 (`CLAUDE.md` / `AGENTS.md`).

2. For tier 2, see what fnord found and enable the sources you want:

   ```bash
   fnord config external list
   fnord config external enable cursor:rules
   fnord config external enable claude:agents
   ```

   At `fnord ask` start, fnord warns (in yellow) about any source that has
   files on disk but is disabled, with the exact enable command.

3. For tier 3, just keep your `CLAUDE.md` / `AGENTS.md` where the other
   tools expect them. fnord's research and code phases are prompted to
   look for these when a task needs project context — but it's on demand,
   not pre-loaded.

4. For "both tools must always honor this," use **two homes**: put the
   authoritative copy in `FNORD.md` (guaranteed for fnord) and your other
   tool's native location (`CLAUDE.md` for Claude Code, `.cursor/rules/`
   for Cursor). Don't rely on one file to cover both tools.

## Expected outcome

- Tier 1 instructions shape every session.
- Enabled tier 2 sources show up in the boot listing (`Cursor skills:`,
  `Claude agents:`, etc.) and inject their catalog at session start.
- Tier 3 files are read mid-session when the task calls for them — visible
  in the session log as `file_contents_tool` reads.

## Common failure modes

- **Your `CLAUDE.md` rule didn't fire** — it's tier 3, best-effort. If it
  must always apply, promote it to `FNORD.md`.
- **A Cursor rule never injected** — the source is disabled. Run
  `fnord config external list` and enable `cursor:rules`. Remember
  `alwaysApply` rules inject at bootstrap; `globs:` (auto-attach) rules
  only fire when a matching file is read or written.
- **A Claude subagent is missing from the catalog** — agents whose
  `tools:` include `Write`/`Edit` are hidden outside edit mode. Re-run with
  `--edit`.
- **A skill caused recursion or was filtered** — skills whose body shells
  back into `fnord ask` are filtered to prevent infinite recursion. Mark
  intentional shims with `fnord_skip: true`.
- **fnord ignored `.github/copilot-instructions.md` or Cursor's UI-stored
  rules** — those are never consumed by any tier. Move the content to a
  file fnord reads.

## Related docs

- [AI Tool Integrations](../user/ai-tool-integrations.md) — the complete
  reference: every source, path, format, and injection point.
- [Skills](../user/skills.md) — reusable agent presets.
- [Project instructions and local overrides](project-instructions-and-local-overrides.md) —
  tier 1 in detail.
