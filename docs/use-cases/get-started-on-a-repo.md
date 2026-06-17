# Get started on a repo

## What this covers

Taking a repository fnord has never seen and getting it to the point
where you can ask useful questions about it: indexing the files, running
your first research questions, and priming persistent notes so later
sessions start smarter. Editing code is out of scope here — see
[Safe edit-mode workflow](safe-edit-mode-workflow.md) for that.

## When to use it

- You just cloned or created a project and want fnord to understand it.
- `fnord ask` is returning thin answers because nothing is indexed yet.
- You're onboarding a teammate (or a future you) to a codebase.

## Prerequisites

- fnord installed and on your `PATH` (see the [main README](../../README.md)).
- An OpenAI API key exported as `OPENAI_API_KEY`.
- A directory you can read. A git repo is ideal — fnord indexes the
  default branch and the commit history — but any directory works.

## Steps

1. Index the project, naming it and pointing at its root. From inside
   the repo:

   ```bash
   fnord index --project myproj --dir .
   ```

   The name is how you'll refer to the project later; the directory is
   stored, so subsequent runs don't need `--dir`.

2. Let it finish. fnord embeds every text file and, in a git repo, walks
   the commit history in the background. Re-running `fnord index` later
   only processes new, changed, and deleted files.

3. Ask your first question. From inside the project directory the
   `--project` flag is inferred from the cwd:

   ```bash
   fnord ask -q "what does this project do and how is it laid out?"
   ```

4. When fnord offers to **prime** the knowledge base (it does this after
   the first index if no notes exist yet), say yes. Priming runs a
   research pass that writes durable project notes fnord reloads every
   session. You can also trigger it explicitly:

   ```bash
   fnord prime
   ```

5. Keep asking. Each session accumulates notes; the
   [learning system](../user/learning-system.md) consolidates them over
   time so answers get sharper.

## Expected outcome

- `fnord projects` lists `myproj`.
- `fnord ask` returns answers that cite real files and commits.
- `fnord notes` shows accumulated project knowledge after priming.
- A later `fnord index` is fast — it only touches changed files.

## Common failure modes

- **"Project not found" on a fresh repo** — you skipped `--dir` on the
  very first index, so fnord never learned where the project lives. Re-run
  with `--project NAME --dir .`.
- **Answers ignore your feature branch** — fnord indexes the repo's
  *default* branch (`main`/`master`), not your working tree. This is by
  design; see [troubleshoot agent context](troubleshoot-agent-context.md).
- **Indexing is slow on a huge repo** — exclude vendored and generated
  trees: `fnord index -x "vendor/*" -x "*.min.js"`. Exclusions persist to
  project config.
- **Binary or non-UTF-8 files are skipped** — expected; fnord only indexes
  text it can split safely.

## Related docs

- [Command Reference](../user/commands.md) — `index`, `ask`, `prime`, `search`.
- [Ask Options](../user/ask-options.md) — flags for `fnord ask`.
- [Learning System](../user/learning-system.md) — priming and notes.
- [Index and embeddings](../user/index-embeddings-migration.md) — refreshing
  the index after upgrades.
