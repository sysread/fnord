---
name: integration-test-ask
description: Smoke-test fnord's `./fnord ask` command against the isolated smoketest fixture. Use when the user wants to verify the ask flow still works end-to-end after a change to the coordinator, completion API, provider abstraction, request builder, response parser, or any code on the ask path. This exercises a real coordinator session with the dev escript and the user's configured AI provider; it makes paid completion API calls.
---

# Smoke test: ./fnord ask

Verifies the ask pipeline against the `smoketest` fixture project.
Exercises provider resolution, request building, response parsing,
tool dispatch, and the coordinator loop. **This makes real completion
API calls.** Cost is small (the fixture and prompt are tiny) but not
zero, and the call count depends on how many tool round trips the
coordinator runs.

## Steps

1. Run the setup skill first:

    ```bash
    bash scripts/integration-setup.sh
    ```

   Capture the `INTEGRATION_HOME=...` line from stdout.

2. Ask a question whose answer is verifiable from the fixture:

    ```bash
    HOME="$INTEGRATION_HOME" ./fnord ask \
      --project smoketest \
      --quiet \
      -q "What does the Hello module's world function return?"
    ```

   The question is deliberately answerable from `hello.ex` alone, so
   any wrong answer indicates a real failure (retrieval, completion,
   or response parsing) rather than ambiguity.

## Pass criteria

- Exit 0.
- Response mentions `"hello, world"` (case-insensitive) somewhere in
  the assistant text.
- No stack traces, no `:error` tuples, no `{:invalid_json, ...}` (a
  classic Venice `<think>`-leak signature).
- The "Tokens used" footer is present (proof the completion actually
  ran; absence means the coordinator bailed early).

## Failure interpretation

- **No answer / hallucinated answer**: retrieval did not surface
  `hello.ex`. Could be a coordinator regression or an indexing
  regression - run the index smoke test first to disambiguate.
- **`{:invalid_json, ...}` in output**: structured-output parser hit
  prose. On Venice this is the `<think>` leak signature; check
  `venice_parameters.strip_thinking_response` is still set in the
  request builder.
- **Provider 4xx with a "model does not support..." message**: a
  capability flag on `AI.Model.t` lies. Cross-check the model's
  factory in `lib/ai/model/<provider>.ex`.
- **Empty / nil response, exit 0**: response parser dropped the
  message. Check the provider's response parser.

## What this does not cover

- Multi-turn conversations (`--follow`, `--fork`)
- Edit mode (`--edit`), worktrees, approvals
- Web search, MCP, frobs, skills-as-tools
- Long contexts that exercise compaction
- Provider switching mid-session

For any of those, write a separate skill targeting that specific
behavior.
