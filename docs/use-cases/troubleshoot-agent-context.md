# Troubleshoot agent context

## What this covers

Figuring out why fnord did or didn't see a particular file, instruction,
or piece of code — the "why didn't it follow my rule / why can't it find
this function / why is it answering about the wrong branch" class of
problems. This is a diagnostic flowchart, not a feature guide.

## When to use it

- An instruction you wrote isn't affecting fnord's behavior.
- fnord can't find code you know exists, or cites stale code.
- fnord seems to be operating against the wrong project or branch.

## The mental model

fnord's awareness of your project comes from a few independent channels.
When something's missing, the question is always *which channel was
supposed to carry it, and did that channel fire?*

- **Instructions** arrive in three tiers (always-loaded `FNORD.md`,
  opt-in external configs, research-discovered `CLAUDE.md`/`AGENTS.md`).
- **Code knowledge** comes from the *index*, which covers the default
  branch — not your working tree.
- **Accumulated knowledge** comes from *notes*, written by priming and
  prior sessions.
- **The target project** is resolved from `-p`/`-W` or the current
  directory, and git operations anchor on the resolved project's root.

## Diagnostic steps

### "My instruction was ignored"

1. Which tier is the instruction in? Only `FNORD.md` / `FNORD.local.md`
   are guaranteed every session. `CLAUDE.md` / `AGENTS.md` are
   best-effort (read only when a task needs them). Cursor/Claude configs
   must have their `external_configs` source **enabled**.
2. Run `fnord config external list` — is the source you expected on?
3. For auto-attach Cursor rules, remember they only fire when a matching
   file is read or written, not at session start. Set
   `FNORD_DEBUG_CURSOR_RULES=1` to trace every rule decision.
4. If it must always apply, move it to `FNORD.md`. See
   [Use fnord with Claude Code and Cursor](use-fnord-with-claude-and-cursor.md).

### "fnord can't find code I know exists" / "it's citing stale code"

1. Is the project indexed, and recently? Re-run `fnord index` — it picks
   up new, changed, and deleted files.
2. **Is the code only on your feature branch?** fnord indexes the repo's
   *default* branch (`main`/`master`), not your working tree. Code that
   lives only on an unmerged branch is invisible to search. This is the
   single most common surprise.
3. Is the file binary or non-UTF-8? Those are skipped at index time.
4. Confirm with `fnord files` (lists indexed files) and `fnord search -q`.

### "It's answering about the wrong project or branch"

1. Run `fnord projects` and confirm which project you mean.
2. Pass `--project NAME` (or `--worktree DIR`) explicitly. Without it, the
   project resolves from the current directory — and if you're running
   `./fnord` from inside the fnord checkout, git operations can anchor on
   *fnord's* repo instead of your target. (Dev gotcha #19.)
3. For edit/review work, anchoring matters most: the reviewer and code
   tools resolve git/`gh` against the project's source root.

## Expected outcome

You can name the channel that failed: a wrong-tier instruction, an unindexed
or branch-only file, or a misresolved project — and apply the matching fix.

## Common failure modes (and the one-line fix)

- **Rule ignored** → wrong tier; promote it to `FNORD.md`, or enable its
  external-configs source.
- **Missing code** → not indexed, or only on a feature branch; re-index, or
  merge to the default branch.
- **Stale answers** → re-run `fnord index`; check whether notes are out of
  date (`fnord notes`, `--reset` to clear).
- **Wrong repo** → pass `--project`/`--worktree`; don't rely on cwd when
  running from another repo.

## Related docs

- [AI Tool Integrations](../user/ai-tool-integrations.md) — the full tier model.
- [Learning System](../user/learning-system.md) — notes and priming.
- [Get started on a repo](get-started-on-a-repo.md) — indexing basics.
- [Command Reference](../user/commands.md) — `index`, `files`, `search`, `notes`.
