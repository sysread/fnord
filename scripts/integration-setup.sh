#!/usr/bin/env bash
# Idempotent setup for fnord integration smoke tests.
#
# Builds the dev escript from the current working tree, prepares an
# isolated `$HOME` under the repo, and seeds a tiny fixture project so
# subsequent test commands have something to index against. Re-running
# this script is safe and cheap; it is intended to be called by every
# integration test skill before exercising a feature.
#
# DRAGON: fnord writes to `$HOME/.fnord`. Running this script with a
# real user `$HOME` would scribble on the user's actual fnord state.
# The script computes its own integration HOME under the repo root and
# refuses to operate against the user's real home directory regardless
# of how it is invoked.
#
# Output contract: on success, the LAST line of stdout is the
# absolute path to the integration HOME, prefixed with `INTEGRATION_HOME=`.
# Skill prompts parse this line to capture the path for subsequent
# `HOME=<path> ./fnord ...` invocations. All diagnostic chatter goes to
# stderr so the contract line stays clean.

set -euo pipefail

log() { printf '[integration-setup] %s\n' "$*" >&2; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# A stable, repo-relative integration HOME. Gitignored; safe to wipe.
# Living under the repo (not /tmp) means the path survives reboots,
# the agent does not need to remember a pid-stamped tmpdir between
# Bash tool calls, and `make clean-integration` (or `rm -rf`) is the
# only teardown.
INTEGRATION_HOME="$REPO_ROOT/.integration-home"

# Refuse to run if someone exported `$HOME` to point at a real user
# home before invoking this script. The integration HOME must always
# be the repo-local path - this script *owns* it.
case "${HOME:-}" in
  "$INTEGRATION_HOME") : ;;
  /Users/*|/home/*|/root|/var/root)
    if [[ "${HOME:-}" != "$INTEGRATION_HOME" ]]; then
      # Only an issue if the agent passes through HOME implicitly to
      # commands we run below. We override HOME ourselves on every
      # `./fnord` invocation, so this is informational.
      log "note: invoked with HOME=$HOME (will override to $INTEGRATION_HOME for fnord)"
    fi
    ;;
esac

mkdir -p "$INTEGRATION_HOME"

log "repo=$REPO_ROOT"
log "integration HOME=$INTEGRATION_HOME"

# Build the dev escript. mix escript.build picks up the working tree,
# including uncommitted changes - that is the whole point of this skill
# pack: smoke-test what you are about to commit, not the released
# binary on PATH.
log "building dev escript..."
make build >&2

# Tiny fixture project. Files are rewritten on every run so the agent
# can rely on their content - editing them by hand would be lossy
# anyway since the integration HOME is not a working surface.
FIXTURE="$INTEGRATION_HOME/fixture"
mkdir -p "$FIXTURE"

cat > "$FIXTURE/README.md" <<'EOF'
# Smoketest fixture

Tiny project used by fnord integration test skills.
The Hello module greets; the Util module shouts.
EOF

cat > "$FIXTURE/hello.ex" <<'EOF'
defmodule Hello do
  @moduledoc "Returns a greeting string."
  def world, do: "hello, world"
end
EOF

cat > "$FIXTURE/util.ex" <<'EOF'
defmodule Util do
  @moduledoc "String helpers used by the smoketest fixture."
  def shout(s), do: String.upcase(s) <> "!"
end
EOF

cat > "$FIXTURE/notes.md" <<'EOF'
# Notes

The Hello module is intentionally trivial. Real fnord features are
exercised by the surrounding test skills, not by anything in this fixture.
EOF

log "fixture=$FIXTURE (4 files)"

# Register the fixture as a fnord project on first run. `./fnord index`
# accepts `--dir` only when the project is unknown; subsequent runs
# resolve the project by name. We treat the absence of the project
# directory under `~/.fnord/projects` as the cue, which is cheaper than
# parsing `./fnord projects` output.
if [[ ! -d "$INTEGRATION_HOME/.fnord/projects/smoketest" ]]; then
  log "registering fixture as project 'smoketest'..."
  HOME="$INTEGRATION_HOME" "$REPO_ROOT/fnord" \
    index --project smoketest --dir "$FIXTURE" --quiet --yes >&2 || {
    log "first-time index failed - leaving partial state for inspection"
    exit 1
  }
else
  log "project 'smoketest' already registered (skipping --dir registration)"
fi

# Final contract line. Parse with `grep '^INTEGRATION_HOME='` from the
# skill body or just `tail -n1`.
printf 'INTEGRATION_HOME=%s\n' "$INTEGRATION_HOME"
