# Safe edit-mode workflow

## What this covers

Letting fnord modify code without wrecking your working tree: turning on
edit mode, how approvals gate shell and file operations, how worktrees
isolate the changes, and how validation rules catch breakage before you
see it. Reviewing the result afterward is its own use case — see
[Review a change](review-a-change.md).

## When to use it

- You want fnord to actually write code, not just describe a change.
- You're nervous about an AI touching your repo and want the guardrails
  explained before you flip the switch.

## The safety model in one breath

Edit mode is **off by default**. When on, fnord can edit files inside the
project root (and `/tmp`) but **cannot run write `git` operations** or
touch files outside the project. Shell and file actions pass through an
**approvals** layer. In a git repo, edits land in a **conversation-bound
worktree**, not your checkout. **Validation rules** run after
code-modifying tool calls to catch breakage early. You review and merge
at the end.

## Prerequisites

- An indexed project (see [Get started on a repo](get-started-on-a-repo.md)).
- For worktree isolation: the project is a git repository.
- A clean-enough working tree that a new worktree won't surprise you.

## Steps

1. Run `ask` with `--edit` (`-e`) and a concrete instruction:

   ```bash
   fnord ask -p myproj --edit -q "add a docstring to lib/foo/thing.ex"
   ```

2. In a git repo, fnord creates or reuses a **single worktree for the
   conversation** and works there. Your primary checkout is untouched.
   Point it at an existing worktree with `--worktree DIR` if you prefer.

3. Approve operations as fnord requests them. Pre-approve recurring,
   trusted commands so you're not prompting on every `mix`:

   ```bash
   fnord config approve --kind shell "mix"
   ```

   See [Approval Patterns](../user/approval-patterns.md) for kinds and
   scoping.

4. Let validation rules run. After code-modifying tool calls, fnord runs
   the project's configured checks (compile, tests, linters) and feeds
   failures back into the session so it can self-correct. Configure them
   per [Validation Rules](../user/validation-rules.md).

5. At session end, review the worktree's changes and merge. With `--yes`,
   fnord skips the interactive post-session review and attempts the usual
   merge-and-cleanup automatically — use it only when you trust the change.

## Expected outcome

- Edits appear in a worktree (or the path you passed), not silently in
  your main checkout.
- Each shell/file action was either pre-approved or explicitly confirmed.
- Validation feedback shows in the session; a green run means the checks
  fnord was given passed.
- You end with a reviewable diff you consciously merge.

## Common failure modes

- **fnord says it can't run a `git` write** — by design. It never commits,
  pushes, or branches on its own; you drive git.
- **It edited fnord's own repo instead of your project** — you ran `./fnord`
  from inside the fnord checkout without `-p`/`-W`, so the git root
  resolved to the wrong repo. Pass `--project` or `--worktree`. See
  [Troubleshoot agent context](troubleshoot-agent-context.md).
- **A Claude subagent you expected wasn't available** — agents needing
  `Write`/`Edit` are hidden outside edit mode; `--edit` unlocks them.
- **Endless approval prompts** — pre-approve the trusted commands with
  `fnord config approve`.
- **"(no file changes during this session)" after real edits** — a known
  edge around context compaction; the change may still be in the worktree.
  Inspect the worktree directly.

## Related docs

- [Worktrees](../user/worktrees.md) — git worktree isolation lifecycle.
- [Approval Patterns](../user/approval-patterns.md) — pre-approving and
  scoping shell/file operations.
- [Validation Rules](../user/validation-rules.md) — auto-run checks after edits.
- [Ask Options](../user/ask-options.md) — `--edit`, `--worktree`, `--yes`.
