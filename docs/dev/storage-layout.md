# Storage Layout

All persistent fnord state lives under `~/.fnord/`, resolved at runtime by
`Settings.fnord_home/0` (`lib/settings.ex:52`). Projects are namespaced under
`~/.fnord/projects/<name>/`; global state lives at the top level.

## Project store tree

Each project directory is created by `Store.Project.create/1`
(`lib/store/project.ex:89`). On-disk layout:

```text
~/.fnord/projects/<name>/
  files/                    # indexed file entries
  commits/index/            # commit embedding index
  conversations/            # conversation JSON files
  conversations/index/      # conversation embedding index
  memory/                   # project-scoped long-term memories
  notes.md                  # LLM-generated research notes
  worktrees/                # git worktrees for edit-mode sessions
```

Subdirectory constants:

- `@files_dir "files"` -- `lib/store/project.ex:20`
- `@conversation_dir "conversations"` -- `lib/store/project.ex:19`
- `@index_dir "commits/index"` -- `lib/store/project/commit_index.ex:36`
- `@index_dir "conversations/index"` -- `lib/store/project/conversation_index.ex:30`

The store path for a project is `~/.fnord/projects/<name>`, built by
`Store.get_project/0` (`lib/store.ex:44`). The `@projects_dir "projects"`
constant is at `lib/store.ex:2`.

## File entries

Each indexed file gets a subdirectory under `files/` keyed by an encoded
identifier. The entry directory contains:

- `metadata.json` -- hash, relative path
- `summary` -- LLM-generated prose summary
- `embeddings.json` -- embedding vector

### Key scheme

`Store.Project.Entry.id_for_rel_path/1` (`lib/store/project/entry.ex:259`)
picks one of two prefixes:

|Prefix|Encoding|When used|
|--------|----------|-----------|
|`r1-`|base64url of the relative path (no padding)|`byte_size("r1-" <> encoded) <= 240`|
|`h1-`|sha256 hex digest of the relative path|path too long for reversible encoding|

The threshold applies to the prefixed id (`"r1-" <> encoded`), not the raw encoded path - see `@max_id_len` and `byte_size(reversible_id)` in `lib/store/project/entry.ex`.
The `r1-` scheme is reversible via `rel_path_from_id/1`.
The `h1-` scheme is a one-way hash; the original path is recovered from `metadata.json` instead.

## Source mode: git vs filesystem

`Store.Project.Source` (`lib/store/project/source.ex`) routes all source
reads, hashes, and listings through a single abstraction. The mode decision
(`mode/1`, line 38) is:

- `:git` when `GitCli.default_branch(root)` returns a branch name
- `:fs` otherwise

### Default branch resolution

`GitCli.default_branch/1` (`lib/git_cli.ex:216`) follows a strict chain:

1. `origin/HEAD` (remote's declared default)
2. Local `main`
3. Local `master`
4. `nil` -- **no current-branch fallback**

Returning nil forces the project into `:fs` mode. This is intentional: indexing
the current branch would make `fnord index` on a feature branch silently index
WIP-only files.

### Hash formats

|Mode|Hash source|Length|
|------|-------------|--------|
|`:git`|git blob SHA from `ls-tree`|40 hex chars|
|`:fs`|sha256 of file content|64 hex chars|

### ls-tree caching

`Source.cached_ls_tree/2` (`lib/store/project/source.ex:96`) stores the
`git ls-tree` result in `:persistent_term`, keyed on `{module, :ls_tree, root, branch}`. Both successes and errors are cached for the BEAM's
lifetime. A single fnord invocation is short-lived, so the branch tip
won't advance during an index run.

## Cross-format hash upgrade

`Entry.hash_is_current?/1` (`lib/store/project/entry.ex:150`) detects when
the stored hash is 64 hex characters (sha256 from a prior fs-mode era) while
the current source mode produces a different hash format (40-char git blob SHA).
If the file content hasn't actually changed (`content_unchanged?/2`, line 178),
metadata is re-stamped in place without a full LLM re-summarize + re-embed pass.

## Per-entry embedding dimension check

`Entry.is_stale?/1` (`lib/store/project/entry.ex:94`) includes an
`embedding_dim_is_current?/1` check (line 111) that reads the stored embedding
vector and compares `length(embedding) == AI.Embeddings.dimensions()`. An entry
with the wrong dimension count is stale regardless of hash freshness. This
catches entries produced by a prior embedding model that the cross-format hash
upgrade would otherwise mark as fresh.

## Global memory store

Long-term global memories live in `~/.fnord/memory/`. Storage is managed by
`Memory.FileStore` (`lib/memory/file_store.ex`), one JSON file per memory,
slugified from the title.

See [memory-system.md](memory-system.md) for scope details and the
promotion pipeline.

## Settings

`~/.fnord/settings.json` -- global configuration including project roots,
exclude lists, and model preferences. Managed by `Settings`
(`lib/settings.ex:64`).
