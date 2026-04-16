# Index and embeddings

Projects that rely on semantic search and commit-aware research use indexed embeddings for files and (when in a git repository) commits. To ensure accurate results after upgrading, refresh the index before your next `ask` session.

Why

- Index data (file and commit embeddings) may be stale relative to your current checkout. Stale embeddings reduce match quality and can hide relevant code or history.

What to do

- Run the indexer to rebuild file and commit embeddings for the active project.

Examples

```bash
fnord index
# or, if first time or after moving the project
fnord index --dir /path/to/project
```

Notes

- Commit indexing runs automatically for git repositories during `fnord index`.
- After indexing completes, start a new `fnord ask` session.
- If results look inconsistent, run `fnord index --reindex` to force a full rebuild.
