# Use cases

End-to-end workflows for getting real work done with fnord.

This lane answers "I'm trying to do X — what's the path, what should I
expect, and where does it bite?" The [user docs](../user/README.md) are
the reference manual (what each command and flag does); these are the
runbooks (how the pieces fit together for a concrete job). When a use
case needs the gory details of a command or setting, it links into the
reference rather than repeating it.

## How these docs are structured

Every use case follows the same shape so you can skim or execute it:

- **What this covers** - the job, and where its edges are.
- **When to use it** - the situation that should send you here.
- **Prerequisites** - project state, tools, and config you need first.
- **Steps** - numbered, imperative; shell commands verbatim.
- **Expected outcome** - what you should observe when it works.
- **Common failure modes** - the ways it goes sideways, and the fix.
- **Related docs** - where to go deeper.

## Index

- [Get started on a repo](get-started-on-a-repo.md) - index a project,
  ask your first questions, prime persistent notes.
- [Project instructions and local overrides](project-instructions-and-local-overrides.md) -
  `FNORD.md` vs `FNORD.local.md`: what goes where, and how conflicts resolve.
- [Use fnord with Claude Code and Cursor](use-fnord-with-claude-and-cursor.md) -
  what's guaranteed-loaded vs opt-in vs research-discovered across tools.
- [Safe edit-mode workflow](safe-edit-mode-workflow.md) - `--edit`,
  approvals, worktrees, and validation rules without wrecking your tree.
- [Review a change](review-a-change.md) - review a branch, PR, or commit
  range with the multi-specialist reviewer.
- [Troubleshoot agent context](troubleshoot-agent-context.md) - figure out
  why fnord did or didn't see a file, instruction, or piece of code.

## Getting help

- Report issues: [GitHub Issues](https://github.com/sysread/fnord/issues)
- Ask fnord directly about its own features — the documentation search
  tool covers this lane and the user guides.
