# Tool System

Tools are the interface between the LLM coordinator and fnord's capabilities.
Each tool is an Elixir module implementing the `AI.Tools` behaviour, registered
in a toolbox map from tool name to module.

## Behaviour

`AI.Tools` (`lib/ai/tools.ex:1`) defines:

### Required callbacks

|Callback|Signature|Purpose|
|----------|-----------|---------|
|`spec/0`|`-> map()`|OpenAI function-calling JSON schema|
|`call/1`|`parsed_args -> raw_tool_result`|Execute the tool|
|`async?/0`|`-> boolean`|Whether the tool runs in a background task|
|`read_args/1`|`map -> {:ok, map} \|args_error`|Validate and extract args|
|`is_available?/0`|`-> boolean`|Runtime availability gate|
|`ui_note_on_request/1`|`args -> {label, detail} \|binary \|nil`|UI label on invocation|
|`ui_note_on_result/2`|`args, result -> {label, detail} \|binary \|nil`|UI label on completion|
|`tool_call_failure_message/2`|`args, reason -> :default \|:ignore \|binary \|{label, detail}`|Custom error message|

### Error shapes

```text
{:error, :missing_argument, name}    -- required arg not present
{:error, :invalid_argument, msg}     -- arg failed validation
{:error, :unknown_tool, name}        -- tool not in toolbox
{:error, msg}                        -- general tool error (binary)
{:error, code, msg}                  -- frob error (non-zero exit code)
```

## Registration

Tools are registered in module-level maps in `AI.Tools` (`lib/ai/tools.ex:172`):

|Map|Purpose|
|-----|---------|
|`@tools`|General-purpose read-only tools|
|`@rw_tools`|File edit, patch, shell, notify|
|`@worktree_tools`|Git worktree operations|
|`@web_tools`|Web search|
|`@ui_tools`|Interactive user prompts (ask, choose, confirm)|
|`@coding_tools`|Coder agent|
|`@review_tools`|Reviewer agent|
|`@task_tools`|Task list management|
|`@skills_tools`|Run/save skills|

### Toolbox construction

`basic_tools/0` (line 265) starts with `@tools`, filtered by `is_available?/0`.
Additional tool sets are layered via `with_*` functions:

- `with_mcps/1` -- MCP tools (lazily started on first use)
- `with_frobs/1` -- user-defined local tools (linters, test runners, etc.)
- `with_rw_tools/1` -- file edit + shell access
- `with_coding_tools/1` -- coder agent
- `with_review_tools/1` -- reviewer agent
- `with_web_tools/1` -- web search
- `with_ui/1` -- interactive UI tools (gated on TTY + non-quiet)
- `with_task_tools/1` -- task list management
- `with_worktree_tool/2` -- git worktree (conditional on boolean flag)
- `with_skills/1` -- skill runner + saver

`all_tools/0` (line 248) includes everything. It is intended for replay and
diagnostics only; normal runs should build toolboxes selectively.

## Tool categories

### File tools (`lib/ai/tools/file/`)

|Module|Tool name|Purpose|
|--------|-----------|---------|
|`Contents`|`file_contents_tool`|Read file content|
|`Edit`|`file_edit_tool`|Apply edits to files|
|`Info`|`file_info_tool`|File metadata and summary|
|`List`|`file_list_tool`|List project files|
|`Notes`|`file_notes_tool`|Per-file research notes|
|`Reindex`|`file_reindex_tool`|Trigger inline re-indexing|
|`Search`|`file_search_tool`|Semantic search over indexed files|

### Memory tools

|Module|Tool name|Purpose|
|--------|-----------|---------|
|`AI.Tools.Memory`|`memory_tool`|Session memory read/write|
|`AI.Tools.LongTermMemory`|`long_term_memory_tool`|Global/project memory CRUD|

### Self-help tools (`lib/ai/tools/self_help/`)

|Module|Tool name|Purpose|
|--------|-----------|---------|
|`Docs`|`fnord_help_docs_tool`|Search hexdocs/GitHub for fnord docs|
|`Cli`|`fnord_help_cli_tool`|CLI structure lookup|

### Agent tools

|Module|Tool name|Purpose|
|--------|-----------|---------|
|`AI.Tools.Coder`|`coder_tool`|Coding sub-agent|
|`AI.Tools.Reviewer`|`reviewer_tool`|Multi-specialist code review|
|`AI.Tools.Cmd`|`cmd_tool`|Shell command execution|

### Other

|Module|Tool name|
|--------|-----------|
|`AI.Tools.WebSearch`|`web_search_tool`|
|`AI.Tools.Git.Worktree`|`git_worktree_tool`|
|`AI.Tools.Research`|`research_tool`|
|`AI.Tools.Notes`|`prior_research`|
|`AI.Tools.Conversation`|`conversation_tool`|
|`AI.Tools.Notify`|`notify_tool`|
|`AI.Tools.ApplyPatch`|`apply_patch`|
|`AI.Tools.Commit.Search`|`commit_search_tool`|
|`AI.Tools.ListProjects`|`list_projects_tool`|

## MCP tools

MCP (Model Context Protocol) tools are loaded lazily on first use via
`Services.MCP.start/0`, triggered by `with_mcps/1` (line 293). MCP tool
modules are generated at runtime by `MCP.Tools.module_map/0` and registered
alongside native tools in the toolbox.

## Tool call flow

1. Coordinator sends a tool-call message
2. `AI.Tools.perform_tool_call/3` (`lib/ai/tools.ex:460`) dispatches:
   - Resolve module via `tool_module/2`
   - Validate args via `module.read_args/1` + `AI.Tools.Params.validate_json_args/2`
   - Call `module.call/1`
   - Normalize result to `{:ok, binary}` or `{:error, binary}`
3. Result returned to coordinator as a tool-result message

Async tools (`async?() == true`) run in background tasks. When the LLM issues
a multi-tool call, async tools run concurrently; sync tools (`async?() == false`)
run sequentially after all async tools complete.

## Write gate

`AI.Tools.require_worktree_if_git/0` (`lib/ai/tools.ex:770`) gates write
operations in git repos. In a git repo, edits must target a worktree (either
fnord-managed or user-supplied via `-W`). Returns an error instructing the LLM
to create a worktree first if no override is set.
