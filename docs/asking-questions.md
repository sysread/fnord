# Advanced Asking Questions

Deep dive into fnord's `ask` command and research capabilities.

## Quick Reference

For basic usage, see the [main README](../README.md#generate-answers-on-demand).

## Research Rounds

By default, fnord performs one round of research per question. A round consists of:
1. Analyzing the question
2. Planning research strategy
3. Executing tool calls (search, read files, git commands, etc.)
4. Synthesizing findings

### Increasing Research Depth

Use `--rounds` to perform multiple rounds of research:

```bash
fnord ask --project myproject --rounds 3 --question "How does authentication work?"
```

**What happens with multiple rounds:**
- Round 1: Initial research, broad exploration
- Round 2: Deeper investigation of interesting findings
- Round 3: Synthesis and connection-making across components

**When to use more rounds:**
- Complex architectural questions
- Questions spanning multiple subsystems
- Large codebases with many interconnected parts
- When initial answer seems incomplete

**Trade-offs:**
- More rounds = better quality, deeper analysis
- More rounds = longer wait time, more API usage
- Default (1 round) is usually sufficient for focused questions

**Examples:**

```bash
# Simple question - 1 round is fine
fnord ask -p myproject -q "Where is the login function defined?"

# Complex question - use more rounds
fnord ask -p myproject --rounds 5 -q "Explain the complete authentication flow from login to token refresh"
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
# Uses ripgrep instead of semantic search
```

### With Index (Recommended)

For best results, index first:
```bash
fnord index --project myproject --dir /path/to/project
fnord ask -p myproject -q "How does authentication work?"
# Uses semantic search + tool calls + learning system
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

### 3. Use More Rounds for Complex Questions

```bash
# Complex architectural question
fnord ask -p myproject --rounds 5 \
  -q "Trace the complete flow from HTTP request to database query and back"
```

### 4. Prime First for New Projects

```bash
fnord index --project myproject --dir /path/to/project
fnord prime --project myproject --rounds 3
# Now ask questions - fnord has baseline knowledge
```

### 5. Leverage Learning System

Ask fnord to review its notes first:

```bash
fnord ask -p myproject --rounds 3 \
  -q "Review your notes about the authentication system, then explain how password reset works"
```

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
- Increase rounds: `--rounds 3` or `--rounds 5`
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
- High number of rounds
- Many tool calls needed
- API rate limiting

**Solutions:**
- Use more specific questions
- Reduce rounds if appropriate
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
