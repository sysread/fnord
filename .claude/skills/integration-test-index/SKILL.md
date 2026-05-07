---
name: integration-test-index
description: Smoke-test fnord's `./fnord index` command against the isolated smoketest fixture. Use when the user wants to verify indexing still works end-to-end after a change to the indexer, embeddings pipeline, store layer, or any code on the index path. This exercises a real index pass with the dev escript and the user's configured AI provider; it makes paid completion API calls for the per-file summary step.
---

# Smoke test: ./fnord index

Verifies the indexing pipeline against the `smoketest` fixture project.
Exercises file walk, splitter, embedding generation, summary
generation, and persistence to the project store. Embeddings are
generated locally (MiniLM), so they cost nothing. **The per-file
summary step does hit the configured AI provider's completion API.**
The fixture is tiny (4 files) so the cost is small, but not zero -
that is the price of running an integration smoke test against the
real provider rather than a stub.

## Steps

1. Run the setup skill first to ensure the dev binary, integration
   HOME, and `smoketest` project all exist:

    ```bash
    bash scripts/integration-setup.sh
    ```

   Capture the `INTEGRATION_HOME=...` line from the script's stdout.

2. Run a re-index pass against the fixture, with the integration HOME
   in scope and the dev binary at the repo root:

    ```bash
    HOME="$INTEGRATION_HOME" ./fnord index --project smoketest --reindex --quiet --yes
    ```

   `--reindex` forces work even when the fixture has not changed, so
   the embedding pipeline actually runs. `--quiet` keeps output tight
   for the agent. `--yes` auto-confirms any approval prompts.

3. Verify the index landed:

    ```bash
    HOME="$INTEGRATION_HOME" ./fnord files --project smoketest
    ```

   The output should list the four fixture files (`README.md`,
   `hello.ex`, `util.ex`, `notes.md`).

## Pass criteria

- Step 2 exits 0.
- Step 3 lists exactly 4 files.
- No stack traces or `:error` tuples in either output.

## Failure interpretation

- **Provider auth errors** (401/403) on the summary step: the user's
  AI provider env vars are missing or wrong. Not an indexing bug;
  surface and stop.
- **Completion API errors** (5xx, rate limits) on summaries: retry
  once, then surface; intermittent upstream failure is not actionable.
- **Embedding errors**: embeddings are generated locally via MiniLM,
  so any failure here points at the local pool, the model load, or
  the splitter - not the provider. Capture the stack and report.
- **File count mismatch**: a real bug. Capture the file list and the
  full `index` output, name the suspect components (file walk,
  exclusion rules, store persistence).
- **Crashes / stack traces**: a real bug. Report the stack trace
  verbatim; do not edit it.

## What this does not cover

- Large repos, deep directory trees, or files near the splitter limit
- Re-index churn (stale/new/deleted detection across runs)
- Git-mode vs filesystem-mode source selection
- Concurrent indexing or interrupt/resume

For any of those, write a separate skill targeting that specific
behavior.
