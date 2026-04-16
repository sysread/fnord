# Developer documentation

Architecture notes for LLMs and contributors working **on** fnord. For user-facing docs (how to use fnord in your own projects), see [`docs/user/`](../user/README.md).

These docs live in the repo and are not published to hexdocs. They're intentionally skeletal — essential shape, key invariants, file:line pointers — and are meant to be refined over time rather than kept exhaustive. fnord indexes them as ordinary markdown, so asking fnord questions about itself will surface content from here via normal file search.

## Where to start

If you're new to the codebase, read in this order:

1. [architecture.md](architecture.md) — top-level system shape.
2. [storage-layout.md](storage-layout.md) — what lives under `~/.fnord/`.
3. [indexing-flow.md](indexing-flow.md) — how `fnord index` works.
4. [ask-coordinator.md](ask-coordinator.md) — how `fnord ask` turns questions into tool calls.
5. [gotchas.md](gotchas.md) — architectural invariants that are non-obvious from reading the code.

Subsystem deep-dives:

- [embeddings-pipeline.md](embeddings-pipeline.md) — local MiniLM-L12-v2 via bundled `embed.exs`.
- [memory-system.md](memory-system.md) — session / project / global memories + promotion.
- [worktree-system.md](worktree-system.md) — git worktree isolation for edit-mode conversations.
- [tool-system.md](tool-system.md) — the `AI.Tools` behaviour and tool registration.

## `docs/dev/` vs `fnord notes`

Two separate stores of project-scoped knowledge — don't conflate them:

- **`docs/dev/`** (this directory): curated, checked-in architecture notes. Stable, version-controlled, reviewed.
- **`fnord notes`** (`Services.Notes`, `~/.fnord/projects/<name>/notes.md`): live observations fnord accumulates across sessions while answering questions. Ephemeral, consolidated over time by the LLM, not curated by humans. Surfaced via `fnord notes` subcommand.

When fnord answers a "how does X work internally?" question, it pulls from both — embedded docs via file search + accumulated notes via the notes tool.

## Conventions for these docs

- Use file:line references liberally (`lib/cmd/index.ex:140`) so readers can follow threads into code.
- Describe the system as it is today; don't narrate how it came to be.
- Match the terse moduledoc style.
- Cross-link siblings where helpful.
- Call out non-obvious contracts explicitly (e.g. "freshness recheck must happen inside the lock") — that's the whole point of having these docs separate from moduledocs.
