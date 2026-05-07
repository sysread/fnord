# Integration test skills

A small set of Claude Code skills that exercise fnord end-to-end against
the dev escript built from the working tree. They live under
`.claude/skills/` and are invoked by name (`integration-setup`,
`integration-test-index`, `integration-test-ask`).

The skills are **smoke tests, not unit tests**. They make real API
calls against whatever AI provider the user has configured, so they
cost real money - tiny amounts, but not zero. Run them when you have
a reason: validating a code change on the ask/index path, confirming
a provider port works end-to-end, reproducing a user-reported bug
against the dev binary.

## What each skill does

- `integration-setup` - builds the dev escript, creates the isolated
  `$HOME`, generates the fixture, and registers the `smoketest`
  project on first run. Idempotent.
- `integration-test-index` - re-indexes the fixture and confirms the
  four files made it into the store.
- `integration-test-ask` - asks a verifiable question against the
  fixture and checks the answer.

Each test skill calls `integration-setup` itself, so they are safe to
run in isolation.

## Architecture

The setup script (`scripts/integration-setup.sh`) owns three things:

1. **Isolated `$HOME`** at `<repo>/.integration-home/`. fnord resolves
   its config root via `Settings.get_user_home/0`, which reads
   `$HOME` directly. Pointing `$HOME` at a repo-local path means
   `~/.fnord/` for fnord becomes `<repo>/.integration-home/.fnord/`,
   leaving the user's real fnord state untouched. The path is
   gitignored. `rm -rf .integration-home/` is the teardown.

2. **Dev escript build** via `make build` (`mix escript.build`). The
   resulting `./fnord` at the repo root reflects the working tree,
   not the released binary on `$PATH`. Skills always invoke `./fnord`
   explicitly to avoid confusion.

3. **Fixture project** at `.integration-home/fixture/` with four small
   files. Files are rewritten on every setup run, so their content is
   guaranteed; do not hand-edit them. The fixture is registered with
   fnord under the project name `smoketest` on first run; subsequent
   runs detect the existing project directory and skip re-registration.

The script's last stdout line is the contract:

```
INTEGRATION_HOME=/Users/.../fnord/.integration-home
```

Skill bodies parse that line and use it as the `HOME=` prefix for
every subsequent fnord invocation. Bash tool calls do not preserve
exported env across invocations, so each fnord command in a test
skill must include the prefix explicitly.

## Why under the repo root, not `/tmp`

The agent runs Bash commands as one-shot subprocesses. A pid-stamped
`/tmp` path would force the agent to remember a UUID across calls.
A repo-local path is stable, predictable, and gitignored; the only
trade-off is that the integration HOME survives across sessions,
which is a feature (you can re-run a single test skill without
re-doing setup) rather than a bug.

## Adding a new integration test skill

1. Pick exactly one feature surface to exercise. If you find yourself
   wanting to test two things, write two skills.
2. Create `.claude/skills/<name>/SKILL.md` with frontmatter
   (`name`, `description`) and a body that:
   - Calls `bash scripts/integration-setup.sh` and captures
     `INTEGRATION_HOME`.
   - Runs the dev binary as
     `HOME="$INTEGRATION_HOME" ./fnord <subcommand> --project smoketest ...`.
   - States explicit pass criteria and failure-mode interpretation.
3. If your test needs a different fixture shape, either add files to
   the existing fixture in `scripts/integration-setup.sh` (cheap,
   shared) or - if the fixture diverges enough that a shared one
   would be confusing - add a second registered project with its own
   layout. Do not introduce per-skill fixture scripts that the agent
   has to remember to run.

## Safety

- The setup script refuses nothing about HOME by default - it always
  overrides `HOME` to the integration path on every fnord call it
  makes. The risk of writing to the user's real `~/.fnord/` is in
  skill bodies that forget the `HOME=` prefix on a fnord command.
  When you write a new skill, check every `./fnord ...` invocation
  for the prefix.
- The integration HOME is repo-local and gitignored, so a runaway
  fnord session cannot scribble outside it.
- Skills should never call `git` against the integration HOME; the
  fixture is not a git repo, and setting up one would only add a way
  to test wrong things.
