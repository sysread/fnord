# Fnord

Fnord is a command line tool the builds a searchable database of your files,
using AI-generated embeddings to index and search your code base, notes, and
other (non-binary) files.

## Installation

1. Install `elixir` if necessary:
```bash
# MacOS
brew install elixir

# Debian-based
sudo apt-get install elixir
```

2. Add the mix escript path to your shell's PATH:
```bash
echo 'export PATH="$HOME/.mix/escripts:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

3. Install the script:
```bash
mix escript.install github sysread/fnord
```

Use the same command to reinstall. It will offer to overwrite the existing
installation.

## Usage

### Indexing

The first time you run this, especially on a large codebase, it will take a
while to index everything. Subsequent runs will be faster, re-indexing only
those files which have changed since they were last indexed.

```bash
fnord index --project foo --dir /path/to/foo
```

You can **reindex** the project, forcing it to reindex all files:

```bash
fnord index --project foo --dir /path/to/foo --reindex
```

### Searching

```bash
fnord search --project foo --query "some search query"
```

If you want more detail about each file matched:

```bash
fnord search --project foo --query "some search query" --detail
```

### Miscellaneous

- **List projects:** `fnord projects`
- **List files in a project:** `fnord files --project foo`
- **Delete a project:** `fnord delete --project foo`

Note that deleting a project only deletes from the index, not the actual files.

## TODO

- Unit tests (*don't judge me*)
- GHA to run unit tests
- Optimize for use as a library
    - Document APIs
- Configurable concurrency limits (currently hard-coded at 4)
- Daemon mode that watches for file changes and updates the index
- Progress bar
- Docs are not auto-publishing
