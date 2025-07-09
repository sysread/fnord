# Fnord

[![Tests | Dialyzer](https://github.com/sysread/fnord/actions/workflows/run-tests.yml/badge.svg)](https://github.com/sysread/fnord/actions/workflows/run-tests.yml)

- [Description](#description)
- [Features](#features)
- [Installation](#installation)
- [Getting Started](#getting-started)
- [Tool usage](#tool-usage)
- [User integrations](#user-integrations)
- [Writing code (EXPERIMENTAL)](#writing-code)
- [Copyright and License](#copyright-and-license)


## Description

`fnord` is a command line tool that uses multiple LLM-powered agents and tools to provide a conversational interface to your codebase, notes, and other (non-binary) files.

It can be used to generate on-demand tutorials, playbooks, and documentation for your project, as well as to search for examples, explanations, and solutions to problems in your codebase.

## Why `fnord`?

AI-powered tools are limited by to the data built into their training data. **RAG (Retrieval-Augmented Generation)** using tool calls can supplement the training data with information, such as your code base, to provide more accurate and relevant answers to your questions.

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

- **Set `OPENAI_API_KEY` in your shell environment**

Set this in your shell environment to the OpenAI project key you wish to use for this tool.
You can create a new project and get a key [here](https://platform.openai.com/api-keys).


- **Optional: Install `ripgrep`**

`fnord` includes tooling for the LLM to use the `ripgrep` tool in addition to semantic search.
This enables the LLM to answer questions about your code base, even if the project has not been indexed yet (with the caveat that the results will be less context-aware).


- **Optional: Install a markdown viewer**

Markdown seems to be the language of choice for LLMs, so installing something like `gum` or `glow` to pipe output to will make the output more readable.
You can make your preferred formatter persistent by setting the `FNORD_FORMATTER` environment variable in your shell.

```bash
export FNORD_FORMATTER="gum format"
```


- **Optional: Install `codex-cli`**

For highly experimental AI-assisted code editing features, you may (optionally) install [`codex-cli`](https://github.com/openai/codex).
If detected and up-to-date (minimum version 0.3.0), `fnord` will allow you to enable file editing through the `ask` command with the `--edit` flag (see below).
Use with extreme caution - see the dedicated section on editing for critical safety details.


## Getting Started

For the purposes of this guide, we will assume that `fnord` is installed and we are using it to interact with your project, `blarg`, which is located at `$HOME/dev/blarg`.


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

`fnord` stores its index in `$HOME/.fnord/$project`.

Although indexing provides full semantic search capabilities and richer results, `fnord` also supports ad-hoc querying on unindexed projects via directory metadata and `ripgrep` fallback, allowing quicker experimentation without full indexing.


### Prime the knowledge base

`fnord` can generate an initial set of learnings about your project to prime its knowledge base.

```bash
fnord prime --project blarg
```


### Configuration

You can view and edit the configuration for your project with the `fnord config` command.

```bash
fnord config list --project blarg
fnord config set --project blarg --root $HOME/dev/blarg --exclude 'node_modules' --exclude 'vendor'
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

`fnord` uses semantic search by default when a project has been indexed. If semantic search is unavailable (because the project is unindexed or the index is missing):

- Semantic search will be disabled with a warning.
- If `ripgrep` is installed and in your PATH, `fnord` will automatically fall back to ripgrep for basic text-based file search.
- If ripgrep is not available, you will see a warning indicating limited search capability.
- This fallback behavior lets you query projects immediately without waiting for a full index, providing fast albeit less context-aware results.


### Generate answers on-demand

`fnord` uses a combination of LLM-powered agents and tool calls to research your question within your project, including access to semantic search and git tools (read only!).

As it conducts its investigation, you will see some of the research steps reported back to you in real-time. These are printed to `STDERR` so they will not interfere with redirected output. If you wish to see more of this, set `LOGGER_LEVEL=debug` in your shell.

```bash
fnord ask --project blarg --question "Where is the unit test for some_function?"
fnord ask --project blarg --question "Find all callers of some_function"
fnord ask --project blarg --question "Is there a function or method that does X?"
fnord ask --project blarg --question "How do I add a new X implementation?"
```

#### Asking questions without prior indexing

You can now use `fnord ask` on projects that have **not yet been indexed** or where the project index is unavailable.

- If the project is already created in `fnord` but not indexed, semantic search will be disabled, and `ripgrep` fallback will be used if available.
- If the project does **not exist in fnord yet**, you can provide the project's root directory with the `--directory` (or `-d`) option when running `fnord ask`.
- This will automatically create the project metadata on demand and allow you to query the project files without requiring a full index upfront.

Example usage:

```bash
# Ask a question about a project without an index by specifying the source directory
fnord ask --project blarg --directory $HOME/dev/blarg --question "Where is the unit test for some_function?"

# Continue to specify the directory if the project has not been indexed or created yet
fnord ask --project new_project --directory /path/to/new_project --question "Explain the main workflow"
```

Note: If semantic search is unavailable and `ripgrep` is not installed, you will receive a warning and limited search capability. To get full semantic search power, please index your project using the `fnord index` command.

#### Improve research quality

By default, `ask` performs a single round of research (multiple tool calls per round notwithstanding).
You can increase the number of rounds with the `--rounds` option.
Increasing the number of rounds will increase the time it takes to generate a response, but can drastically improve the quality and thoroughness of the response, especially in large code bases or code bases containing multiple apps.

```bash
fnord ask --project blarg --question "Please confirm that all information in the README is up-to-date and correct. Identify user-facing functionality that is not well-documented." --rounds 3
```

#### Continuing a conversation

Conversations (the transcript of messages between the LLM and the application) are saved for future reference and continuation. After each response, you will see a message like:
```
Conversation saved with ID: c81928aa-6ab2-4346-9b2a-0edce6a639f0
```

If desired, you can use that ID to continue the conversation with `--conversation`.

```bash
fnord ask --project blarg --conversation c81928aa-6ab2-4346-9b2a-0edce6a639f0 --question "Is some_function still used?"
```

...or can continue the _most recently saved conversation_ with `--follow`.

```bash
fnord ask --project blarg --follow --question "Is some_function still used?"
```


List conversations with the `conversations` command.

```bash
fnord conversations --project blarg
```

Prune conversations older than a certain number of days with the `--prune` option.

```bash
# Prune conversations older than 30 days
fnord conversations --project blarg --prune 30
```

#### Replaying a conversation

You can also `replay` a conversation, replicating the output of the original question, research steps, and response.

```bash
fnord replay --project blarg --conversation c81928aa-6ab2-4346-9b2a-0edce6a639f0 | glow
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
- List projects: `fnord projects`
- List files in a project: `fnord files --project foo`
- Delete a project: `fnord torch --project foo`


## Tool usage

All of the tool calls available to `fnord` are available for external use via the `tool` subcommand.

```bash
# List available tools
fnord help tool

# Get help for a specific tool
fnord tool --tool file_search_tool --help

# Call the tool
fnord tool --tool file_search_tool --project blarg --query "some_function definition"
fnord tool --tool file_info_tool --project blarg --file "path/to/some_module.ext" --question "What public functions are defined in this file?"
```


## User integrations

Users can create their own integrations, called frobs, that `fnord` can use as a tool call while researching.
Just like built-in tools, these are usable through the `fnord tool` subcommand.

```bash
# Create a new integration
fnord frobs create --name my_frob

# Validate the frob
fnord frobs check --name my_frob

# List frobs
fnord frobs list

# List frobs that are registered for a project
fnord frobs list --project blarg
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


## Writing code
Fnord can (optionally) automate code changes in your project using the `ask` command with the `--edit` flag, if [`codex-cli`](https://github.com/openai/codex) is installed and detected (minimum version 0.3.0).

HIGHLY EXPERIMENTAL!
- Use `--edit` with extreme caution.
- AI-driven code modification is unsafe, may corrupt or break files, and must always be manually reviewed.

### How it works
The AI will suggest *atomic, minimal steps* for code changes, and these are passed to `codex-cli`, which attempts to apply them.

```bash
fnord ask --project myproj --edit --question "Add a docstring to foo/thing.ex"
```

### Safeguards and sandboxing (codex-cli arguments)
To minimize risk, fnord invokes codex-cli with these strong safety settings:
- `--cd <project root>`: Only operates inside your project directory.
- `--sandbox workspace-write`: Codex can only *write* files inside the workspace (project), and cannot touch files elsewhere; it can read any file for context.
- `--full-auto`: Runs in automatic mode (approval policy: on-failure) - commands run without prompts unless they fail.
- `--config disable_response_storage=true`: Codex does *not* store your data or code.
- `--skip-git-repo-check`: Lets codex run in non-git projects.
- Model is set by fnord internally for consistency.

**See also:**
- [codex-cli documentation](https://github.com/openai/codex#readme)
- [config reference](https://github.com/openai/codex/blob/main/codex-rs/config.md)

**Fnord configures the AI's instructions to strictly prohibit:**
- Making changes outside your project/workspace.
- Adding/removing files unless *explicitly* required.
- Touching code outside the specified region, function, or file.
- Unrelated refactoring, formatting, or guessing.

**Despite all this,** code modification by an LLM is *unreliable* and is not safe for unsupervised use - codex or the AI may behave unpredictably.

### User Responsibility
- Every code change is your responsibility. 
- **Manual review is **required** - AI may hallucinate, omit, or corrupt changes.**
- Automated editing is always opt-in, disabled by default, and only available if codex-cli is present and new enough.


## Copyright and License

This software is copyright (c) 2025 by Jeff Ober.

This is free software; you can redistribute it and/or modify it under the MIT License.
