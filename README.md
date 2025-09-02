# Fnord

[![Tests | Dialyzer](https://github.com/sysread/fnord/actions/workflows/run-tests.yml/badge.svg)](https://github.com/sysread/fnord/actions/workflows/run-tests.yml)

- [Description](#description)
- [Features](#features)
- [Installation](#installation)
- [Getting Started](#getting-started)
- [Tool usage](#tool-usage)
- [User integrations](#user-integrations)
- [Writing code](#writing-code)
- [Copyright and License](#copyright-and-license)


## Description

`fnord` is a command line tool that uses multiple LLM-powered agents and tools to provide a conversational interface to your codebase, notes, and other (non-binary) files.
It can be used to generate on-demand tutorials, playbooks, and documentation for your project, as well as to search for examples, explanations, and solutions to problems in your codebase.

## Why `fnord`?

AI-powered tools are limited to the data built into their training data. **RAG (Retrieval-Augmented Generation)** using tool calls can supplement the training data with information, such as your code base, to provide more accurate and relevant answers to your questions.
But even with RAG, the AI still runs up against the **context window**. This is the conversational "memory" of the AI, often making use of an "attention mechanism" to keep it focused on the current instructions, but causing it to lose track of details earlier in the conversation.
If you've ever pasted multiple files into ChatGPT or worked with it iteratively on a piece of code, you've probably seen this in action. It may forget constraints you defined earlier in the conversation or hallucinate entities and functions that don't exist in any of the files you've shown it.
`fnord` attempts to mitigate this with cleverly designed tool calls that allow the LLM to ask _other_ agents to perform tasks on its behalf. For example, it can generate a prompt to ask another agent to read through a file and retrieve specific details it needs, like a single function definition, the declaration of an interface, or whether a specific function behaves in a certain way. This keeps the entire file out of the "coordinating" agent's context window while still allowing it to use the information in the file to generate a response. This allows `fnord` to conduct more complex research across many files and directories without losing track of the details it needs to provide accurate answers.


## Features

- Semantic search
- On-demand explanations, documentation, and tutorials
- Git archaeology
- Learns about your project(s) over time
- Improves its research capabilities with each interaction
- User integrations
- Layered approvals for shell/file operations
- MCP server tools (Hermes/OpenAI MCP)


## Installation

Fnord is written in [Elixir](https://elixir-lang.org/) and is distributed as an `escript`.

- **Install [elixir](https://elixir-lang.org/)**
```bash
# MacOS
brew install elixir

# Debian-based
sudo apt-get install elixir
```

- **Add the `escript` path to your shell's PATH**
```bash
echo 'export PATH="$HOME/.mix/escripts:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

- **Install `fnord`**
```bash
mix escript.install github sysread/fnord
```

- **Set your OpenAI API key**

Fnord reads the key from either `FNORD_OPENAI_API_KEY` or `OPENAI_API_KEY`.
Create or view your keys [here](https://platform.openai.com/api-keys).

- **Optional: Install `ripgrep`**

`fnord` includes tooling for the LLM to use the `ripgrep` tool in addition to semantic search.
This enables the LLM to answer questions about your code base, even if the project has not been indexed yet (with the caveat that the results will be less context-aware).


- **Optional: Install a markdown viewer**

Markdown seems to be the language of choice for LLMs, so installing something like `gum` or `glow` to pipe output to will make the output more readable.
You can make your preferred formatter persistent by setting the `FNORD_FORMATTER` environment variable in your shell.

```bash
export FNORD_FORMATTER="gum format"
```


## Getting Started

For the purposes of this guide, we will assume that `fnord` is installed and we are using it to interact with your project, `blarg`, which is located at `$HOME/dev/blarg`.

## Tool usage

### Index your project

The first step is to index your project to make it searchable with `fnord`'s semantic search capabilities.
The first time you index your project may take a while, especially if there are a lot of files.
`fnord` respects `.gitignore`, but you may also wish to exclude certain paths or globs from indexing (e.g., `-x 'node_modules'`).

```bash
fnord index --project blarg --dir $HOME/dev/blarg --exclude 'node_modules'
```

If you cancel partway-through (for example, with `Ctrl-C`), you can resume indexing by running the same command again.

You must re-index your project to reflect changes in the code base, new files, deleted files, or to change the directory or exclusions.
This is done by running the same command again.

`fnord` stores its index under `$HOME/.fnord/projects/<project>`.

Note that semantic search requires an existing index. You can still perform text searches via the shell tool (e.g., ripgrep) if installed and approved, but indexing is recommended for full capabilities.


### Prime the knowledge base

`fnord` can generate an initial set of learnings about your project to prime its knowledge base.

```bash
fnord prime --project blarg
```
Prime uses 3 research rounds by default.


### Configuration

You can view and edit the configuration for existing projects with the `fnord config` command.

```bash
fnord config list --project blarg
fnord config set --project blarg --root $HOME/dev/blarg --exclude 'node_modules' --exclude 'vendor'
```


### Approval patterns

```bash
fnord config approvals --project <project>            # list project approvals (use --global for global)
fnord config approve   --project <project> --kind <kind> '<regex>'
# add to global scope instead of project:
fnord config approve   --global --kind <kind> '<regex>'
```


### Search your code base

`fnord`'s semantic search is powered by embeddings generated by OpenAI's `text-embedding-3-large` model. The indexing process does a lot more than simply generate embeddings for the contents of your files. It also generates summary documentation for each file as well as an index of all functions, entities, and symbols in each file to enhance semantic matches for common questions and symbols.

```bash
fnord search --project blarg --query "callers of some_function"
fnord search --project blarg --query "some_function definition"
fnord search --project blarg --query "unit tests for some_function"
```

The summaries generated by the indexing process can also be included in the search results with the `--detail` flag.

```bash
fnord search --project blarg --query "some_function declaration" --detail | glow
```

If you would like to see more information about a single file, you can use the `summary` command.

```bash
fnord summary --project blarg --file "path/to/some_module.ext" | glow
```


### Search behavior and fallbacks

`fnord` uses semantic search by default when the project has been indexed.
For `fnord search`, an index is required; without it you won't get semantic results.
You can still ask questions, and the AI may use shell_tool-assisted text searches (for example, ripgrep) if installed and approved.
For rich, accurate results, index your project first.


### Generate answers on-demand

`fnord` uses a combination of LLM-powered agents and tool calls to research your question within your project, including access to semantic search and git tools (read only!).

As it conducts its investigation, you will see some of the research steps reported back to you in real-time. These are printed to `STDERR` so they will not interfere with redirected output. If you wish to see more of this, set `LOGGER_LEVEL=debug` in your shell.

```bash
fnord ask --project blarg --question "Where is the unit test for some_function?"
fnord ask --project blarg --question "Please confirm that all information in the README is up-to-date and correct." --rounds 3
fnord ask --project blarg --follow c81928aa-6ab2-4346-9b2a-0edce6a639f0 --question "Is some_function still used?"
fnord ask --project blarg --fork c81928aa-6ab2-4346-9b2a-0edce6a639f0 --question "How do I update documentation?"

#### Asking questions on an unindexed project

If you haven't indexed yet, set up a project first (either run `fnord index --project <name> --dir <path>` or configure the root with `fnord config set --project <name> --root <path>`). Then you can run `fnord ask ...`. Semantic search will be unavailable until you index, but the AI may use shell_tool-assisted text searches (e.g., ripgrep) if installed and approved.

#### Improve research quality

By default, `ask` performs a single round of research (multiple tool calls per round notwithstanding).
You can increase the number of rounds with the `--rounds` option.
Increasing the number of rounds will increase the time it takes to generate a response, but can drastically improve the quality and thoroughness of the response, especially in large code bases or code bases containing multiple apps.


After each response, you'll see:

```bash
Conversation saved with ID: c81928aa-6ab2-4346-9b2a-0edce6a639f0
```
Continue it with `--follow <ID>` or branch a new thread with `--fork <ID>`.
```bash
fnord ask --project blarg --follow c81928aa-6ab2-4346-9b2a-0edce6a639f0 --question "Is some_function still used?"
```


```bash
fnord conversations --project blarg
fnord conversations --project blarg --prune 30
```

#### Replaying a conversation

You can replay a conversation (last-used or with `--follow <ID>`) using:
```bash
fnord ask --project blarg --replay --follow c81928aa-6ab2-4346-9b2a-0edce6a639f0 | glow
```
As it learns more about your project, `fnord` will be able to answer more complex questions with less research.


### Learning over time

`fnord` learns about your project over time by saving facts and inferences it makes about the project while researching your questions. These facts and inferences are saved and made
searchable in the project's data in the `$HOME/.fnord` directory.

You can view the facts learned thus far, organized by topic, with the `notes` command.

```bash
fnord notes --project blarg | glow
```

Over time, these can become quite extensive, redundant, and stale over time as your code base evolves.

`fnord` knows how to "prime the pump" for its learning process with an initial set of learnings.

```bash
fnord ask --project blarg --question "Prime your research notes and report your findings"
```


### Upgrades

`fnord` is under active development and new features are added regularly. To upgrade to the latest version, simply run:

```bash
fnord upgrade
```

Note that this is just a shortcut for:

```bash
mix escript.install github sysread/fnord
```


### Other commands
- List projects:        `fnord projects`
- List files:           `fnord files --project <project>`
- View file summary:    `fnord summary --project <project> --file <path>`
- View notes:           `fnord notes --project <project>`  (use `--reset` to clear)
- Delete a project:     `fnord torch --project <project>`
- Upgrade fnord:        `fnord upgrade`

## User integrations

Users can create their own integrations, called frobs, that `fnord` can use as a tool call while researching.

### Create a new integration

```bash
fnord frobs create --name my_frob
```

### Validate a frob

```bash
fnord frobs check --name my_frob
```

### List frobs

```bash
fnord frobs list
```

Frobs are stored in `$HOME/fnord/tools` and are comprised of the following files:
- `my_frob/registry.json` - a JSON file that identifies the projects for which the frob is available
- `my_frob/spec.json` - a JSON file describing the frob's calling semantics in [OpenAI's function spec format](https://platform.openai.com/docs/guides/function-calling?api-mode=responses#defining-functions)
- `my_frob/main` - a script or binary that performs the requested task

Make your tool available to your projects: edit the `registry.json` file created when you ran `fnord frobs create` to include the project name(s) for which you want the frob to be available.

```json
{
  // When true, the frob is available to all projects and the "projects" field is ignored.
  "global": true,

  // An array of project names for which fnord should make the frob available. Superseded by the "global" field when set to true.
  "projects": ["blarg", "some_other_project"]
}
```

Implementing the frob: the `main` file is a script or binary that implements the frob. `fnord` passes information to the frob via shell environment variables:

- `FNORD_PROJECT`: The name of the currently selected project
- `FNORD_CONFIG`: The project configuration from `$HOME/.fnord/settings.json` as a single JSON object
- `FNORD_ARGS_JSON`: JSON object of LLM-provided arguments

Testing your frob: if you prefix your `fnord ask` query with `testing:`, you can ask the LLM to test your frob to confirm it is working as expected.

```bash
fnord ask -p blarg -q "testing: please confirm that the 'my_frob' tool is available to you"
fnord ask -p blarg -q "testing: please make a call to 'my_frob' with the arguments 'foo' and 'bar' and report the results"
```

### MCP servers

```bash
# List configured servers (use --global for global scope, --effective for merged view)
fnord config mcp list --project <project> [--global] [--effective]

# Add a stdio server
fnord config mcp add <name> --transport stdio --command ./my_server \
  --arg --flag --env API_KEY=xyz [--global]

# Add an HTTP server
fnord config mcp add <name> --transport streamable_http --base-url https://api.example.com \
  --header 'Authorization=Bearer ...' [--global]

# Update or remove
fnord config mcp update <name> [--transport ...] [--command ...] [--base-url ...] [...]
fnord config mcp remove <name> [--global]

# Validate connectivity and enumerate tools
fnord config mcp check --project <project> [--global]
```


## Writing code
Fnord can (optionally) automate code changes in your project using the `ask` command with the `--edit` flag.

**HIGHLY EXPERIMENTAL!**
- Use `--edit` with extreme caution.
- AI-driven code modification is unsafe, may corrupt or break files, and must always be manually reviewed.

### How it works
The LLM has access to several tools that allow it to modify code within the project directory and perform basic file management tasks.
It *cannot* perform write operations with `git` or act on files outside of the project's root and `/tmp`.

```bash
fnord ask --project myproj --edit --question "Add a docstring to foo/thing.ex"
```

Code modification by an LLM is *unreliable* and is not safe for unsupervised use.
The AI may behave unpredictably.

## Copyright and License

This software is copyright (c) 2025 by Jeff Ober.

This is free software; you can redistribute it and/or modify it under the MIT License.
