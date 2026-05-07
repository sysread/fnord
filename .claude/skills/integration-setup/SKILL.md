---
name: integration-setup
description: Prepare an isolated $HOME with a fresh fnord dev escript and a tiny indexed fixture project for integration smoke tests. Use when the user asks to set up an integration test environment, or as the first step inside another integration-test-* skill. The setup is idempotent and safe to run before any integration test skill that needs the dev binary or the smoketest project.
---

# Integration test setup

Prepares the sandbox that the `integration-test-*` skills run against:

1. Builds the fnord dev escript from the working tree (uncommitted changes included).
2. Creates an isolated `$HOME` at `<repo>/.integration-home/` so all
   fnord state (settings, projects, conversations) stays out of the
   user's real `~/.fnord/`.
3. Generates a tiny fixture project and registers it with fnord under
   the name `smoketest`.

The setup is idempotent: re-running rebuilds the escript (cheap when
nothing changed) and reuses the existing fixture and project
registration. Every integration test skill should call this skill
first; the cost is bounded.

## How to run

Run the script directly:

```bash
bash scripts/integration-setup.sh
```

The script's last stdout line is the contract:

```
INTEGRATION_HOME=/Users/.../fnord/.integration-home
```

Capture that path. Every fnord invocation in subsequent test steps
must be prefixed with `HOME=$INTEGRATION_HOME` so it talks to the
isolated state, not the user's real `~/.fnord/`. The `./fnord` binary
itself is the dev build at the repo root - never use the `fnord` on
`PATH`, which is the released version and ignores your working tree.

## Failure modes to surface

- `make build` failure: report verbatim; the user's working tree does
  not compile and that is the bug they need to know about.
- First-time index failure: usually a missing or invalid AI provider
  key. Surface the exit code and the last lines of stderr; do not
  attempt to "fix" by setting envs.
- `git rev-parse` failure: the script must run inside the fnord repo.
  Report and stop.

## What this skill does NOT do

- It does not run any integration test. That is the job of the
  individual `integration-test-*` skills.
- It does not configure an AI provider. The user's existing provider
  setup (env vars, settings) is inherited - the integration HOME
  starts empty and resolves provider per the usual precedence chain.
- It does not tear down. To wipe state, `rm -rf .integration-home/`
  and re-run.
