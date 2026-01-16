# Advanced Asking Questions

Deep dive into fnord's `ask` command and research capabilities.

## Quick Reference

For basic usage, see the [main README](../README.md#generate-answers-on-demand).

## Persistent Research Notes

fnord learns from each session and retains knowledge across questions in the same project.
This allows it to build a knowledge base over time.
To provide baseline context, use `fnord prime --project <project>` before asking questions.

Examples:

```bash
fnord ask -p myproject -q "Where is the login function defined?"

# Follow-up question – retains context
fnord ask -p myproject -f <conversation_id> -q "Where is the idp configuration loaded?"

# Prime project knowledge before deep questions
fnord prime -p myproject
fnord ask -p myproject -q "Trace the complete flow from HTTP request to database query and back"
```

## Asking Questions on Unindexed Projects

You don't need a semantic index to ask questions, but you do need a configured project.

### Without Index

**Setup:**
```bash
# Configure project root (no indexing)
fnord config set --project myproject --root /path/to/project
```

**What works:**
- ✅ Tool-based research (ripgrep, git commands)
- ✅ File reading and analysis
- ✅ Learning system
- ❌ Semantic search (requires index)

**Limitations:**
- Searches use text-based tools (ripgrep) instead of semantic search
- Less contextual understanding
- May miss relevant code that doesn't match keywords
- Slower for broad exploratory questions

**Example:**
```bash
fnord ask -p myproject -q "Find all files that reference 'authentication'"
# ...uses ripgrep instead of semantic search
```

### With Index (Recommended)

For best results, index first:
```bash
fnord index --project myproject --dir /path/to/project
fnord ask -p myproject -q "How does authentication work?"
# ...uses semantic search + tool calls + learning system
```

## Conversation Management

### Starting a Conversation

```bash
fnord ask --project myproject --question "Where is the user model defined?"
```

After the response, you'll see:
```
Conversation saved with ID: c81928aa-6ab2-4346-9b2a-0edce6a639f0
```

### Continuing a Conversation

Use `--follow` to continue in the same context:

```bash
fnord ask -p myproject --follow c81928aa-6ab2-4346-9b2a-0edce6a639f0 \
  --question "How is the user model used in authentication?"
```

**Benefits of following:**
- Maintains context from previous questions
- Can reference earlier findings
- Builds on accumulated knowledge
- More efficient (less re-research)

### Branching a Conversation

Use `--fork` to branch off into a new direction:

```bash
fnord ask -p myproject --fork c81928aa-6ab2-4346-9b2a-0edce6a639f0 \
  --question "What about the admin user model?"
```

**When to fork vs follow:**
- `--follow`: Same topic, building on previous answer
- `--fork`: Related but different direction, keeping original context

### Viewing Conversations

List all conversations:
```bash
fnord conversations --project myproject
```

### Pruning Old Conversations

Remove conversations older than N days:
```bash
fnord conversations --project myproject --prune 30
```

## Replaying Conversations

View a past conversation without re-executing research:

```bash
# Replay most recent
fnord ask --project myproject --replay

# Replay specific conversation
fnord ask --project myproject --replay --follow c81928aa-6ab2-4346-9b2a-0edce6a639f0

# Pipe through markdown viewer
fnord ask -p myproject --replay --follow <ID> | glow
```

**Use cases:**
- Review past research
- Share findings with teammates
- Document architectural decisions
- Export project knowledge

## Debugging Research

### Viewing Research Steps

By default, fnord shows high-level research progress on STDERR.

**See more detail:**
```bash
LOGGER_LEVEL=debug fnord ask -p myproject -q "your question"
```

This shows:
- Tool calls being made
- Search queries executed
- Files being read
- LLM reasoning steps

**Output separation:**
- STDOUT: Final answer (pipeable to other tools)
- STDERR: Research progress and debugging

**Example:**
```bash
# Save answer, see research steps
LOGGER_LEVEL=debug fnord ask -p myproject -q "..." > answer.md
```

### Understanding Tool Calls

During research, fnord may use:
- **Semantic search** - Find relevant code
- **File reading** - Read specific files
- **Git commands** - Check history, blame, log
- **Ripgrep** - Text-based search (when approved)
- **Frobs** - Your custom tools
- **MCP tools** - External server tools

Watch for tool call patterns that indicate:
- Broad exploration (many searches)
- Deep investigation (reading many related files)
- Historical analysis (git commands)
- External data gathering (MCP/frob calls)

## Research Quality Tips

### 1. Be Specific

**Vague:**
```bash
fnord ask -p myproject -q "How does this work?"
```

**Better:**
```bash
fnord ask -p myproject -q "How does the JWT token validation work in the authentication middleware?"
```

### 2. Ask Follow-ups

Don't try to get everything in one question:

```bash
# First question
fnord ask -p myproject -q "Where is authentication handled?"

# Follow up
fnord ask -p myproject --follow <ID> -q "How does it integrate with the database?"

# Go deeper
fnord ask -p myproject --follow <ID> -q "What happens if token validation fails?"
```

### 3. Prime First for New Projects

```bash
fnord index --project myproject --dir /path/to/project
# Now ask questions - fnord has baseline knowledge
```

### 4. Leverage Learning System

Ask fnord to review its notes first:

```bash
fnord ask -p myproject -q "Review your notes about the authentication system, then explain how password reset works"
```

### 5. Use FNORD.md (and FNORD.local.md) for Project Context

If `FNORD.md` is located in your project root, it is used to enrich the conversation with project-specific context. You can also include an optional `FNORD.local.md` for personal or local instructions; it is appended after the shared FNORD.md and takes precedence on conflicts unless the user's prompt explicitly overrides. To get the best results, keep these files concise (ideally under 500 lines) and focused on key architectural notes, important modules, and coding conventions. Note that if they are large, they will affect context window management and attention allocation.


## Advanced Options

### Output Formatting

```bash
# Markdown (default)
fnord ask -p myproject -q "..." | glow

# Plain text
fnord ask -p myproject -q "..."

# Save to file
fnord ask -p myproject -q "..." > answer.md
```

### Saving Formatted Output 

You can also use `--save` (`-S`) to save the raw markdown output (before `FNORD_FORMATTER`):
```bash
fnord ask -p myproject -S -q "..."
```
The file is saved to `~/fnord/outputs/<project_id>/<slug>.md`, where the slug is derived from the first `# Title: ...` line.

### Quiet Mode

Suppress research progress (only show answer):

```bash
fnord ask -p myproject --quiet -q "..."
```

### Worktrees

Work on a specific git worktree:

```bash
fnord ask -p myproject --worktree /path/to/worktree --edit \
  -q "Add validation to the user model"
```

## Combining with Other Commands

### Search then Ask

```bash
# Find relevant files
fnord search -p myproject -q "authentication"

# Ask detailed question about findings
fnord ask -p myproject -q "Explain how the authentication flow works"
```

### Ask then Review

```bash
# Get answer
fnord ask -p myproject -q "How are errors handled?"

# Review learned knowledge
fnord notes -p myproject | grep -i error
```

## Troubleshooting

### Incomplete Answers

**Try:**
- Ask follow-up questions
- Be more specific in your question
- Ensure project is indexed

### Off-topic Responses

**Try:**
- Reference specific files or components
- Use follow-up to correct course
- Check that question relates to your code (not general programming)

### Slow Research

**Causes:**
- Large codebase with many potential matches
- Many tool calls needed
- API rate limiting

**Solutions:**
- Use more specific questions
- Ensure good semantic index quality
- Prime knowledge base for better context

### Missing Context

**Try:**
- Use `--follow` to maintain context
- Prime project first: `fnord prime -p myproject`
- Ask fnord to review notes before answering
- Provide more context in question

## Further Reading

- [Main README](../README.md)
- [Learning System](learning-system.md)
- [Frobs Guide](frobs-guide.md) - Add custom research tools
- [MCP Advanced](mcp-advanced.md) - Integrate external tools
