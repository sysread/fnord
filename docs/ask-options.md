# Ask Options

Advanced options for `fnord ask`.

## Basic usage

```bash
fnord ask -q "how does the auth middleware work?"
fnord ask -q "refactor the config module" --edit
```

## Model tuning

### --smart / -s

Use a more capable (and more expensive) model for the response.
Trades speed and cost for improved accuracy on complex questions.

### --reasoning / -R LEVEL

Set the AI's reasoning depth.
Levels: `minimal`, `low`, `medium`, `high`.

Higher reasoning produces more thorough analysis but uses more tokens and takes longer.

### --frippery / -V LEVEL

Set model verbosity.
Levels: `low`, `medium`, `high`.

Controls how verbose or terse the AI's response style is.

## Edit mode

### --edit / -e

Permit the AI to create, modify, and delete files in the project.
Without this flag, the AI operates in read-only mode.

### --yes / -y

Auto-approve file edit prompts.
Requires `--edit`.
Can be repeated (`-yy`) to also auto-approve potentially dangerous operations.

In a git repository (where edits are sandboxed to a worktree), `--yes` also auto-merges and cleans up the worktree at the end of the session without prompting.

### --auto-approve-after / -A SECONDS

Automatically approve pending edit prompts after SECONDS of no user input.
Mutually exclusive with `--auto-deny-after`.

### --auto-deny-after / -D SECONDS

Automatically deny pending edit prompts after SECONDS of no user input.
Default: 180 seconds (3 minutes).
Mutually exclusive with `--auto-approve-after`.

### --worktree / -W PATH

Override the project source root for this run.
PATH must be an existing directory.
See [Worktrees](worktrees.md) for the full worktree lifecycle.

## Conversation management

### --follow / -f UUID

Continue an existing conversation.
The AI retains context from prior messages.

### --fork / -F UUID

Create a new conversation branched from an existing one.
The new conversation starts with a copy of the original's messages but diverges from the fork point.

### --replay / -r

Replay a conversation to stdout (use with `--follow`).

## Output

### --save / -S

Save the AI's response to `~/fnord/outputs/<project>/<slug>.md`.

### --tee / -t FILE

Write a clean transcript of the conversation to FILE.
Prompts before overwriting an existing file.

### --TEE / -T FILE

Like `--tee`, but truncates an existing file without prompting.

### --quiet / -Q

Suppress normal UI output.

## What the output footer shows

After each response, fnord prints:

- Duration
- Token usage and context window percentage
- Conversation ID (also copied to clipboard)
- Active worktree path (if any)
- Index staleness (new, changed, deleted files since last index)
- Memory counts (session, project, global)
