# CLAUDE.md

Orientation for Claude Code, Cursor, and other research-driven agents
working **on** the fnord codebase. This file gets you your bearings fast;
it is not the rulebook.

## Authority

**`FNORD.md` is the source of truth for how to work in this repo** —
conventions, testing rules, comment style, the quality gate, the
do-not-commit/push boundaries. Read it before changing code. Nothing here
overrides or duplicates it; when in doubt, `FNORD.md` wins.

This is not a hierarchy you can lean on for guaranteed loading: fnord
itself only guarantees injection of `FNORD.md` / `FNORD.local.md`. This
`CLAUDE.md` is *research-discovered* — fnord and other tools read it when a
task needs orientation, not on every session. Durable, must-always-apply
rules belong in `FNORD.md`, not here.

## What fnord is

An AI-powered code-archaeology and editing CLI, built as an Elixir
escript (single app, not an umbrella). It gives LLM agents tool-call
access to a codebase via semantic search, persistent notes, and a
multi-agent coordinator. **This repository is the runtime for the
assistant** — edits here change how the assistant behaves.

## Where to start reading

- **`FNORD.md`** — conventions and guidelines. First stop.
- **`docs/dev/`** — architecture notes for contributors/LLMs. Read the doc
  covering any subsystem before you touch it; start with
  [`docs/dev/README.md`](docs/dev/README.md) and
  [`docs/dev/gotchas.md`](docs/dev/gotchas.md).
- **`docs/user/`** — how end users drive fnord (commands, config, integrations).
- **`docs/use-cases/`** — end-to-end user workflows (runbooks).

## Working norms (see `FNORD.md` for the full text)

- Run `make check` before finalizing — it's the canonical quality gate
  (compile with warnings-as-errors, tests, dialyzer, markdownlint, docs).
- Never commit or push unless explicitly instructed.
- Keep diffs small and covered by tests.
- Update the relevant `docs/dev/` doc in the same change when you alter
  documented behavior; record new gotchas in `docs/dev/gotchas.md`.
