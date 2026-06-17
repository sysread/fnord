# Project instructions and local overrides

## What this covers

Steering fnord's behavior in a specific project with checked-in
instructions (`FNORD.md`) and personal, uncommitted ones
(`FNORD.local.md`): what belongs in each, how they're loaded, and how
conflicts resolve. Cross-tool files like `CLAUDE.md` and Cursor rules are
a different mechanism — see
[Use fnord with Claude Code and Cursor](use-fnord-with-claude-and-cursor.md).

## When to use it

- fnord keeps making a choice you want to standardize for the whole team.
- You have personal preferences (verbosity, a scratch dir, a pet command)
  that shouldn't land in version control.
- You're deciding where a given instruction should live.

## Prerequisites

- A project fnord can resolve (indexed, or run from inside the repo).
- Write access to the project root.

## The two files

Both live at the **project source root** and are read by
`Store.Project.project_prompt/1` at every session start, injected as a
system message. There is no toggle — if present, they load.

| File | Scope | Commit it? | Use for |
| --- | --- | --- | --- |
| `FNORD.md` | Shared, authoritative | Yes | Team-wide conventions fnord must always follow |
| `FNORD.local.md` | Personal, machine-local | No (`.gitignore` it) | Your own preferences and workflow constraints |

When both exist, fnord reads `FNORD.md` first and appends
`FNORD.local.md`. **Local instructions win on conflict** unless your
prompt says otherwise.

## Steps

1. Create `FNORD.md` at the repo root with durable, shared rules — coding
   standards, testing expectations, safety constraints, "always do X
   before Y." Write it as authoritative project policy.

2. Commit `FNORD.md`. It's part of the project's contract now.

3. If you have personal preferences, create `FNORD.local.md` and add it
   to `.gitignore`:

   ```bash
   echo "FNORD.local.md" >> .gitignore
   ```

4. Put machine-local or personal-only guidance in `FNORD.local.md` —
   tone, a local scratch directory, temporary workflow constraints.

5. Verify both are being seen: start a session and ask fnord to restate
   the project instructions it loaded.

## What goes where

**`FNORD.md`** — guaranteed-injected, shared:

- Coding/testing/doc conventions the whole team relies on.
- Safety rules ("never touch migrations without flagging it").
- Invariants and gotchas specific to this repo.
- Anything that must apply on *every* fnord session here.

**`FNORD.local.md`** — guaranteed-injected, personal:

- Your preferred verbosity or interaction style.
- Local paths and tools that only exist on your machine.
- Temporary reminders you don't want to inflict on teammates.

## Expected outcome

- `FNORD.md` content shapes every session for everyone on the project.
- `FNORD.local.md` shapes only your sessions and never shows up in `git status`.
- When the two disagree, your local file wins — handy for overriding a
  team default on your own machine without editing the shared file.

## Common failure modes

- **`FNORD.local.md` got committed** — it wasn't in `.gitignore`. Remove
  it from tracking (`git rm --cached FNORD.local.md`) and ignore it.
- **Instructions seem ignored** — confirm the file is at the *source
  root*, not a subdirectory, and that you're running against the right
  project. See [Troubleshoot agent context](troubleshoot-agent-context.md).
- **You put cross-tool guidance in `FNORD.md` and expected Cursor/Claude
  to read it** — they don't read `FNORD.md`. That's the wrong lane; see
  [Use fnord with Claude Code and Cursor](use-fnord-with-claude-and-cursor.md).

## Related docs

- [AI Tool Integrations](../user/ai-tool-integrations.md) — the full
  loading model across all prompt-file types.
- [Main README — Project prompts](../../README.md#user-integrations) — the
  one-paragraph summary.
