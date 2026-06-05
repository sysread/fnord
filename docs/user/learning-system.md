# Learning System

Fnord accumulates project knowledge as it researches questions, then reuses that context in later sessions.
That knowledge now lives in two places: project notes and searchable memory.

## How it works

As fnord researches your project, it can:

1. Search indexed code and git history
2. Save project-level notes
3. Recall project and global memories that match the current task
4. Record new session memories that can later be promoted into longer-lived memory

This makes later questions faster and more grounded in prior work.

## Viewing learned knowledge

### Notes

Project notes are the high-level markdown summary of what fnord has learned:

```bash
fnord notes --project myproject
```

Output is markdown, so piping through a viewer can help:

```bash
fnord notes --project myproject | glow
```

### Memory

Project and global memory are searchable separately from notes:

```bash
fnord memory --project myproject
fnord memory --project myproject --query "authentication flow"
fnord memory --global --query "preferred testing pattern"
```

## Priming the knowledge base

Generate an initial set of project notes without asking a specific question:

```bash
fnord prime --project myproject
```

Priming is a good fit when:

- You just indexed a new project
- The project changed substantially
- You want a fresh high-level summary before asking detailed questions

A common flow is:

```bash
fnord index --project myproject
fnord prime --project myproject
fnord notes --project myproject | glow
```

## Knowledge growth over time

Knowledge grows naturally as you use fnord:

1. **Ask questions** - fnord gathers facts while researching
2. **Follow up** - later questions can build on the same context
3. **Recall memory** - relevant project and global memories are pulled into the session
4. **Reflect** - session takeaways can be recorded for future recall

Example:

```bash
# First question
fnord ask -p myproject -q "Where is authentication handled?"

# Follow-up on the same thread
fnord ask -p myproject --follow <ID> -q "How does it integrate with the database?"

# Later question using accumulated context
fnord ask -p myproject -q "What's the pattern for adding a new API endpoint?"
```

## Managing knowledge

### Storage

Project notes live in:

```text
~/.fnord/projects/<project>/notes.md
```

Project memory is stored separately under the project store, and global memory lives under `~/.fnord/memory/`.
Use the CLI to inspect and search those stores rather than editing files directly.

### When knowledge goes stale

Stale knowledge usually shows up as:

- References to code that moved or was removed
- Architecture summaries that no longer match the repo
- Advice that reflects an old convention

Good fixes, in order:

1. **Re-index** when the code has changed substantially

   ```bash
   fnord index --project myproject
   ```

2. **Ask a targeted update question** about the changed area

   ```bash
   fnord ask -p myproject -q "The authentication module changed. Re-check its structure and update your understanding."
   ```

3. **Re-prime** when you want a refreshed top-level summary

   ```bash
   fnord prime --project myproject
   ```

### Redundancy and cleanup

Notes and memory can overlap a bit over time.
The right first move is usually to ask fnord to re-check and correct its understanding rather than hand-editing stored files.

For example:

```bash
fnord ask -p myproject -q "Review your current project knowledge, re-check it against the codebase, and correct any redundant, dated, or incorrect information."
```

If the project summary itself feels off, re-prime after re-indexing.

## Integration with search

The learning system complements the rest of fnord's research stack:

- **Semantic index** - finds relevant code
- **Notes** - hold a project-level summary
- **Memory** - recalls prior conclusions and preferences
- **Git history** - explains how behavior changed over time

Together, these give fnord both current code context and prior research context.

## Best practices

1. Prime after the first index of a project
2. Use `--follow` when the second question depends on the first
3. Re-index after large code changes
4. Ask targeted correction questions when notes or memory feel stale
5. Review `fnord notes` and `fnord memory --query ...` occasionally to see what context fnord is carrying forward

## Technical details

### What gets stored

Fnord can retain:

- Code structure and organization
- Project conventions and patterns
- Relationships between modules and systems
- Domain-specific terminology
- User or project preferences captured as memory

It should not retain secrets or other sensitive values.

### Research flow

When fnord researches a question, it can combine:

1. Prior notes and memory recall
2. Semantic search over indexed code
3. Direct file inspection and tool calls
4. Git history when the question is historical
5. New findings recorded back into notes or memory

## Project context

If present in the project root, `FNORD.md` and `FNORD.local.md` are injected as system instructions each session.
`FNORD.local.md` is appended after `FNORD.md`, so it is the natural place for per-user local guidance.
Adding `FNORD.local.md` to `.gitignore` is still the right move for a private local file.

## Troubleshooting

### `fnord notes` returns nothing

Prime the project or ask a few questions first:

```bash
fnord prime --project myproject
fnord ask -p myproject -q "What is the overall architecture of this project?"
```

### Notes or memory seem outdated

Re-index if needed, then ask fnord to re-check the changed area or re-prime the project summary.

### Too much overlap in stored knowledge

Ask fnord to re-check and clean up its understanding, then re-prime if the high-level summary still feels messy.

## Further reading

- [Main README](../README.md)
- [Advanced Asking Questions](asking-questions.md)
- [Search Documentation](../README.md#search-your-code-base)
