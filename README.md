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
- Writing code with ~fancy autocomplete~ AI assistance
- Git archaeology
- Persistent learning about your projects over time
- Persistent conversational memory
- Improves its research capabilities with each interaction
- Layered approvals for shell/file operations
- User integrations
- MCP server support


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

**Once indexed, `fnord` will automatically reindex while the `ask` command is running if it detects changes to the code base.**

You can also manually re-index your project at any time to pick up changes.
This is done by running the same command again.

`fnord` stores its index under `$HOME/.fnord/projects/<project>`.

Note that semantic search requires an existing index. You can still perform text searches via the shell tool (e.g., ripgrep) if installed and approved, but indexing is recommended for full capabilities.

**Warning:** If you have _just_ created your OpenAI API key, you are likely to encounter rate limits when indexing project (or otherwise using fnord).  OpenAI has API rate limits restricted by [usage tiers](https://platform.openai.com/docs/guides/rate-limits#usage-tiers).

### Prime the knowledge base

`fnord` can generate an initial set of learnings about your project to prime its knowledge base.

```bash
fnord prime --project blarg
```


### Configuration

You can view and edit the configuration for existing projects with the `fnord config` command.

```bash
fnord config list --project blarg
fnord config set --project blarg --root $HOME/dev/blarg --exclude 'node_modules' --exclude 'vendor'
```


### Approval patterns

For safety, fnord requires approval for shell commands and file operations. You'll be prompted to approve operations as fnord works. To streamline your workflow, you can pre-approve specific commands using regex patterns. See [docs/approval-patterns.md](docs/approval-patterns.md) for details.


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

Fnord uses LLM-powered agents and tool calls to research your question, including semantic search and git tools (read only).

```bash
fnord ask --project blarg --question "Where is the unit test for some_function?"

# Continue a conversation
fnord ask --project blarg --follow <ID> --question "Is some_function still used?"
```

After each response, you'll see a conversation ID. Use `--follow <ID>` to continue the conversation or `--fork <ID>` to branch a new thread.

Use the `--save` (or `-S`) flag to save the raw assistant response (before `FNORD_FORMATTER`) to a file.
By default, files are written under `~/fnord/outputs/<project_id>/<slug>.md`.
The `<slug>` comes from the first line `# Title: ...` in the response.
```bash
fnord ask --project blarg -S --question "Explain foo's behavior"
```

For advanced options (e.g., unindexed projects, replaying conversations), see [docs/asking-questions.md](docs/asking-questions.md).


### Learning over time

Fnord learns about your project while researching your questions. It saves facts and inferences it makes, building a searchable knowledge base that improves over time. As the knowledge base grows, fnord can answer increasingly complex questions with less research.

You can prime this learning process with:

```bash
fnord prime --project blarg
```

For managing and viewing learned knowledge, see [docs/learning-system.md](docs/learning-system.md).


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

### Project prompts
Create a project-level `FNORD.md` file at your project's root for project-specific guidance and optionally a `FNORD.local.md` file for personal instructions. When both exist, fnord reads `FNORD.md` first and appends `FNORD.local.md`, with the local file taking precedence on conflicts unless explicitly overridden in your prompt. We recommend adding `FNORD.local.md` to your `.gitignore` to avoid committing personal instructions.

### Frobs
Create custom tools (frobs) that fnord can use while researching. Use frobs to query project-specific APIs, check deployment status, retrieve GitHub PR details for review, or gather information from Kubernetes clusters.

```bash
fnord frobs create --name my_frob
fnord frobs check --name my_frob
fnord frobs list
```

Frobs are stored in `~/.fnord/tools`. For implementation details, see [docs/frobs-guide.md](docs/frobs-guide.md).

### MCP support

MCP servers extend fnord with external tools and data sources. Add servers for GitHub, Kubernetes, project-specific APIs, or any MCP-compatible service.

```bash
# Add a stdio server
fnord config mcp add <name> --transport stdio --command ./server

# Add an HTTP server
fnord config mcp add <name> --transport http --url https://api.example.com

# Add with OAuth (auto-configures everything)
fnord config mcp add <name> --transport http --url https://api.example.com --oauth
fnord config mcp login <name>
```

**Advanced Configuration:** For complete command reference, custom transport options, and manual configuration, see [docs/mcp-advanced.md](docs/mcp-advanced.md).

#### OAuth Authentication

Fnord supports OAuth2 for MCP servers with automatic discovery and registration:

```bash
fnord config mcp add myserver --transport http --url https://example.com --oauth
fnord config mcp login myserver
```

For advanced OAuth options, troubleshooting, and security details, see [docs/oauth-advanced.md](docs/oauth-advanced.md).


## Writing code
Fnord can (optionally) automate code changes in your project using the `ask` command with the `--edit` flag.

- Use `--edit` with extreme caution.
- AI-driven code modification is unsafe, may corrupt or break files, and must always be manually reviewed.
- Optionally add `--yes` to pre-approve edits without prompting.

### How it works
The LLM has access to several tools that allow it to modify code within the project directory and perform basic file management tasks.
It *cannot* perform write operations with `git` or act on files outside of the project's root and `/tmp`.

```bash
fnord ask --project myproj --edit --question "Add a docstring to foo/thing.ex"
```

**You can also use `--worktree` to specify a git worktree path to operate within.**

```bash
fnord ask --project myproj --worktree /path/to/myproj-wt --edit --question "Add a docstring to foo/thing.ex"
```

Code modification by an LLM is *unreliable* and is not safe for unsupervised use.
The AI may behave unpredictably.

## Copyright and License

This software is copyright (c) 2025 by Jeff Ober.

This is free software; you can redistribute it and/or modify it under the MIT License.
