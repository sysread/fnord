# Fnord

[![Tests | Dialyzer](https://github.com/sysread/fnord/actions/workflows/run-tests.yml/badge.svg)](https://github.com/sysread/fnord/actions/workflows/run-tests.yml)

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

### Index

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

You can also watch the project for changes and reindex them as they happen
using [watchman](https://github.com/facebook/watchman). Just be sure to use
`--quiet` to suppress interactive output:

```bash
watchman-make -p '**/*' --settle 5 --run "fnord index --project $project --dir $project_root --quiet"
```

...or use the `fnord-watch` script in the [tools directory](tools/fnord-watch).

```bash
fnord-watch -p foo -d /path/to/foo
```

### Search

```bash
fnord search --project foo --query "some search query"
```

If you want more detail about each file matched:

```bash
fnord search --project foo --query "some search query" --detail
```

### Ask

You can ask the AI assistant to answer questions about your project:

```bash
fnord ask foo "how do you run the tests for this project?"

# Continue the conversation
fnord ask -C foo "how does the test coverage look to you?"

# With status messages emitted to stderr
fnord ask -C -v foo "if the test coverage is so amazing then how come my change didn't break any tests?!"

# Pipe output to `glow` to render markdown
fnord ask foo "summarize the dependencies of this project" -v | glow
```

### Miscellaneous

- **List projects:** `fnord projects`
- **List files in a project:** `fnord files --project foo`
- **Show the AI-generated summary of a file:** `fnord summary --project foo --file bar`
- **Delete a project:** `fnord delete --project foo`

Note that deleting a project only deletes from the index, not the actual files.

## TODO
- `ask`: read questions from stdin
- `ask`: use streaming api
