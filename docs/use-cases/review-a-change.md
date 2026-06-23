# Review a change

## What this covers

Getting a multi-specialist AI review of a set of changes — a branch, a
GitHub PR, or an explicit commit range — and understanding what the
reviewer is good for and what it isn't. The review runs inside a
`fnord ask` session via the reviewer tool; there is no separate `review`
subcommand.

## When to use it

- Post-implementation pass on a branch before you open a PR.
- Pre-merge quality check on an existing PR.
- Auditing a span of commits that touched many files.

Not for a quick single-file sanity check — just read the file, or ask
fnord a plain question about it.

## How target selection works

You always name **exactly one** target. The reviewer reads it via git
directly, so it does **not** need to be checked out in your working tree —
it fetches refs as needed. For remote-qualified refs like `fork/parent`, it
tries that named remote first and otherwise falls back to `origin`.

| Target | Meaning | Range reviewed |
| --- | --- | --- |
| branch | a branch name | `merge-base(branch, base)..branch` |
| pr | a GitHub PR number (needs `gh`) | `merge-base(head, base)..head` |
| range | an explicit `A..B` / `A...B` | exactly that range |

`base` defaults to the reviewed branch's configured upstream when one
exists, otherwise the repo's default branch. A self-tracking upstream
like `origin/my-branch` is not a meaningful review base and will hard-
fail; the same is true if you explicitly pass the branch itself as
`base`. Pass the real parent branch explicitly in that case. Override it
for stacked branches when the branch is not tracking the parent you want
reviewed against (set it to the parent branch, not `main`).

## Prerequisites

- An indexed project, run with the right `-p`/`-W` so git/`gh` operations
  anchor on *that* project, not fnord's own repo.
- For PR review: the `gh` CLI installed and authenticated.

## Steps

1. Start a session and ask fnord to review, naming the target and giving
   it design context — intent, risky areas, what "done" looks like:

   ```bash
   fnord ask -p myproj -q "review the branch feature-x; focus on the new \
     approval-gating path and whether error handling is complete"
   ```

2. Let it work. The reviewer triages complexity, decomposes a large diff
   into focused units, and fans out scoped specialists in parallel. It is
   **not safe to run concurrently** — one review per fnord process.

3. Read the unified report: deduplicated and grouped by severity.

4. Act on findings. To fix them, switch to
   [edit mode](safe-edit-mode-workflow.md); the reviewer itself only
   reports.

## Expected outcome

- A single, severity-grouped report covering the named range.
- Findings cite specific files and lines in the change.
- No edits to your tree — review is read-only.

## Common failure modes

- **It reviewed the wrong repo / `gh pr view` hit fnord** — you ran
  `./fnord` without `-p`/`-W`, so git resolved to fnord's own checkout.
  Always pass the project. (This is gotcha #19 in the dev docs.)
- **"only one of branch, pr, range may be set"** — the target params are
  mutually exclusive; name exactly one. Don't pass the others as empty
  strings or `0`.
- **PR review fails** — `gh` isn't installed or authenticated, or the PR
  number is wrong.
- **Stacked-branch review shows noise from the parent** — either set the
  branch's upstream to the parent branch or pass `base` explicitly so the
  merge-base is computed against the right parent.
- **Review seems to hang or conflict** — another review is already running
  in the same process; they don't run concurrently.

## Related docs

- [Safe edit-mode workflow](safe-edit-mode-workflow.md) — fixing what the
  review finds.
- [Command Reference](../user/commands.md) — the `ask` command.
- [AI Tool Integrations](../user/ai-tool-integrations.md) — the reviewer
  consults `FNORD.md`/project guidelines during the pipeline.
