# Fnord

[![Tests | Dialyzer](https://github.com/sysread/fnord/actions/workflows/run-tests.yml/badge.svg)](https://github.com/sysread/fnord/actions/workflows/run-tests.yml)

Fnord is a command line tool that uses multiple AI-powered agents and tools to
provide a conversational interface to your codebase, notes, and other
(non-binary) files.

## Features
- Code base search
- Graph search and pathfinding
- On-demand playbooks assembled from documentation and code
- Troubleshooting and debugging
- Git archaeology

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

4. Set `OPENAI_API_KEY`

Set this in your shell environment to the OpenAI project key you wish to use
for this tool. You can create a new project and get a key
[here](https://platform.openai.com/api-keys).

## Usage

### Index

The first step is to index your project. This will scan all files in the
project directory and create a searchable database.

The initial index, especially on a large codebase, can will take a while.
Subsequent runs will be faster, re-indexing only those files which have changed
since they were last indexed.

The `--dir` option is required only for the initial indexing. Subsequent
indexing will use the directory specified in the initial index.

```bash
fnord index --project foo --dir /path/to/foo
```

You can **reindex** the project, forcing it to reindex all files.

```bash
fnord index --project foo --dir /path/to/foo --reindex
```

You can also watch the project for changes and reindex them as they happen
using [watchman](https://github.com/facebook/watchman). Just be sure to use
`--quiet` to suppress interactive output.

```bash
watchman-make -p '**/*' --settle 5 --run "fnord index --project $project --dir $project_root --quiet"
```

...or use the `fnord-watch` script in the [tools directory on
GitHub](https://github.com/sysread/fnord/blob/main/tools/fnord-watch).

```bash
fnord-watch -p foo -d /path/to/foo
```

### Search

Search for files in the project that match a query.

```bash
fnord search --project foo --query "some search query"
```

If you want more detail about each file matched:

```bash
fnord search --project foo --query "some search query" --detail
```

### Ask

Ask the AI assistant to answer questions about your project.

```bash
fnord ask foo "how do you run the tests for this project?"

# Pipe output to `glow` to render markdown
fnord ask foo "summarize the dependencies of this project" | glow
```

### Miscellaneous

- **List projects:** `fnord projects`
- **List files in a project:** `fnord files --project foo`
- **Show the AI-generated summary of a file:** `fnord summary --project foo --file bar`
- **Delete a project:** `fnord delete --project foo`

Note that deleting a project only deletes from the index, not the actual files.

## Tool usage

Internally, the `ask` command uses the OpenAI chat completions API to generate
a response, implementing a function tool to allow the assistant to query the
database for information.

`fnord` can be used to implement a similar tool for your own projects. While
the `ask` command severely limits the parameters that the assistant may utilize
(`query` only, with `project` being provided by the user's invocation of the
command), the following syntax includes the full set of parameters available
for the `search` command.

```json
{
  "name": "search_tool",
  "description": "Searches for matching files and their contents in a project.",
  "parameters": {
    "type": "object",
    "properties": {
      "project": {
        "type": "string",
        "description": "Project name for the search."
      },
      "query": {
        "type": "string",
        "description": "The search query string."
      },
      "detail": {
        "type": "boolean",
        "description": "Include AI-generated file summary if set to true."
      },
      "limit": {
        "type": "integer",
        "description": "Limit the number of results (default: 10)."
      },
      "concurrency": {
        "type": "integer",
        "description": "Number of concurrent threads to use for the search (default: 4)."
      }
    },
    "required": ["project", "query"]
  }
}
```

# TODO
- abstract agents out into a behaviour
  ✓ support for tool calls
  - support for "accumulator" agents
- user-configurable system prompt for a given project
- ask: report how old the index is
- tool to allow the assistant to save observations about the project
  - automatically index these observations and either:
    - make them searchable
    - include them in the prompt
