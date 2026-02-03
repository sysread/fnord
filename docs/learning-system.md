# Learning System

Fnord builds a searchable knowledge base about your project as it researches your questions, improving its ability to answer complex questions over time.

## How It Works

As fnord researches your questions, it:

1. Makes observations about your code
2. Draws inferences about architecture and patterns
3. Saves facts organized by topic
4. Makes this knowledge searchable for future questions

This accumulated knowledge helps fnord:

- Answer complex questions faster
- Make better connections between code components
- Understand project-specific terminology and patterns
- Provide more accurate and contextual responses

## Viewing Learned Knowledge

See what fnord has learned about your project:

```bash
fnord notes --project myproject
```

Output is markdown, so pipe through a markdown viewer:

```bash
fnord notes --project myproject | glow
```

### Notes Organization

Notes are organized by topic:

- **Architecture** - System design, component relationships
- **Patterns** - Coding patterns, conventions observed
- **Domain Knowledge** - Business logic, terminology
- **Technical Details** - APIs, data structures, algorithms
- **Testing** - Test strategies, coverage areas

## Priming the Knowledge Base

Generate an initial set of learnings without asking specific questions:

```bash
fnord prime --project myproject
```

**What priming does:**

- Explores project structure and organization
- Identifies key components and their relationships
- Documents common patterns and conventions
- Creates initial set of searchable facts

**Options:**

```bash
fnord prime --project myproject
fnord notes --project myproject | glow
```

**When to prime:**

- After initial indexing of a new project
- After major refactoring or architecture changes
- When notes become stale or outdated

## Knowledge Growth Over Time

The knowledge base grows naturally through use:

1. **Ask questions** - Each research session adds new facts
2. **Follow-up questions** - Builds deeper understanding
3. **Cross-file insights** - Connects related components
4. **Pattern recognition** - Identifies recurring structures

**Example progression:**

```bash
# First question
fnord ask -p myproject -q "Where is authentication handled?"
# Learns: auth module location, basic structure

# Follow-up
fnord ask -p myproject --follow <ID> -q "How does it integrate with the database?"
# Learns: database integration patterns, models used

# Later question
fnord ask -p myproject -q "What's the pattern for adding a new API endpoint?"
# Can now reference learned patterns and conventions
```

## Managing Knowledge

### Knowledge Storage

Notes are stored in: `~/.fnord/projects/<project>/notes.md`

Structure:

```
~/.fnord/projects/myproject/
└── notes.md          # Consolidated learned knowledge
```

### Dealing with Staleness

As your codebase evolves, some learned facts may become outdated:

**Signs of stale knowledge:**

- Fnord references old code that's been refactored
- Architecture descriptions don't match current state
- Pattern recommendations no longer apply

#### Solutions

##### **Re-prime** - Regenerate knowledge base

```bash
# Backup old notes if desired
mv ~/.fnord/myproject/notes ~/.fnord/myproject/notes.backup

# Re-prime
fnord prime --project myproject
```

##### **Targeted updates** - Ask specific questions about changed areas

```bash
fnord ask -p myproject -q "The authentication module has been refactored. Please analyze its new structure and update your understanding."
```

##### **Re-index** - Refresh semantic index to match current code

```bash
fnord index --project myproject
```

### Dealing with Redundancy

Over time, notes may accumulate redundant or overlapping information.

**Current approach:**

- Manual review via `fnord notes`
- Re-priming periodically to consolidate

**Note:** Automatic deduplication/consolidation is a potential future enhancement.

## Integration with Semantic Search

The learning system complements semantic search:

| Feature | Purpose | When Used |
| --- | --- | --- |
| **Semantic Index** | Find relevant code | Every search and ask |
| **Learned Notes** | Understand context | Complex questions requiring connections |
| **Git History** | Track changes | Historical questions |

Together, these create a comprehensive understanding of your project.

## Best Practices

1. **Prime after indexing** - Start with a solid knowledge foundation

   ```bash
   fnord index --project myproject
   fnord prime --project myproject
   ```

2. **Let it grow naturally** - Ask questions as they arise, knowledge accumulates
3. **Use follow-up questions** - Builds deeper, more connected understanding
4. **Provide feedback** - Correct the LLM with `--follow` when it makes a mistake, confuses concepts, or breaks conventions
5. **Re-prime periodically** - After major changes or when notes feel stale
6. **Review notes occasionally** - Understand what fnord knows about your project: `fnord notes --project myproject | glow > project-knowledge.md`

## Technical Details

### Storage Format

Notes are stored as structured markdown with topic categorization and metadata for semantic search integration.

### Research Process

When fnord researches a question:

1. Searches learned notes for relevant context
2. Performs semantic search on code
3. Executes tool calls as needed
4. Synthesizes findings
5. Saves new insights to notes

### Learning Scope

Fnord learns:

- ✅ Code structure and organization
- ✅ Patterns and conventions
- ✅ Component relationships
- ✅ Domain-specific terminology
- ❌ Not: Sensitive data, credentials, secrets

## Project context

If present in the project root, `FNORD.md` and `FNORD.local.md` are injected as system instructions each session.
The local file is appended after the shared file and takes precedence on conflicts unless the user's prompt explicitly overrides.
We recommend adding `FNORD.local.md` to `.gitignore` as a per-user configuration file.

## Troubleshooting

### Notes command returns nothing

**Cause:** No knowledge has been accumulated yet

**Solution:**

```bash
# Prime the knowledge base
fnord prime --project myproject

# Or ask some questions first
fnord ask -p myproject -q "What is the overall architecture of this project?"
```

### Notes seem outdated

**Cause:** Code has changed since notes were generated

**Solution:** Re-prime or ask targeted update questions (see [Managing Knowledge](#managing-knowledge) above)

### Too much redundant information

**Cause:** Overlapping learning from multiple research sessions

**Solution:** Provide feedback:

```bash
fnord ask -p myproject -q "Review your memories. Use the memory tool to remove redundant, dated, and incorrect information."
```

**Solution:** Re-prime to consolidate:

```bash
mv ~/.fnord/myproject/notes ~/.fnord/myproject/notes.old
fnord prime --project myproject
```

**Solution:** Edit notes manually:
As a final resort, you can directly edit the notes file:

```bash
nvim ~/.fnord/projects/<myproject>/notes.md
```

## Future Enhancements

Potential improvements to the learning system:

- Automatic fact consolidation and deduplication
- Versioned knowledge tracking (matching git commits)
- Knowledge export/import for team sharing
- Confidence scoring for learned facts
- Active learning (requesting clarification)

## Further Reading

- [Main README](../README.md)
- [Advanced Asking Questions](asking-questions.md)
- [Search Documentation](../README.md#search-your-code-base)
