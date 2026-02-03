# Frobs Developer Guide

Frobs (short for "frobnicate") are custom tools you create that fnord can use as function calls while researching questions about your project.

## Quick Start

For basic frob commands, see the [main README](../README.md#user-integrations).

## What Are Frobs?

Frobs allow you to extend fnord's capabilities by creating custom tools tailored to your workflow. When fnord researches a question, it can call your frobs just like it calls built-in tools (semantic search, git commands, etc.).

**Example use cases:**

- Query a project-specific API
- Run custom analysis scripts
- Check deployment status
- Query internal documentation systems
- Perform domain-specific calculations

## Frob Structure

Each frob is a directory in `~/.fnord/tools/` containing three files:

```
~/.fnord/tools/
└── my_frob/
    ├── spec.json        # Tool specification
    └── main             # Implementation (script or binary)
```

### Creating a Frob

```bash
fnord frobs create --name my_frob
```

This creates the directory structure and template files.

### Enabling a Frob

Enable your frob for a project using the CLI or the UI Settings:

```bash
# Enable for the current project
fnord frobs enable --name my_frob
# Or enable globally
fnord frobs enable --name my_frob --global
```

### Disabling a Frob

```bash
# Disable for the current project
fnord frobs disable --name my_frob
# Or disable globally
fnord frobs disable --name my_frob --global
# Or disable for a specific project
fnord frobs disable --name my_frob --project other_project
```

## Configuration Files

### 1. spec.json

### 2. spec.json

Describes the frob's interface using [OpenAI's function calling format](https://platform.openai.com/docs/guides/function-calling):

```json
{
  "name": "my_frob",
  "description": "Brief description of what this tool does",
  "parameters": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "The query parameter"
      },
      "limit": {
        "type": "integer",
        "description": "Maximum number of results",
        "default": 10
      }
    },
    "required": ["query"]
  }
}
```

**Important:**

- `name` must match the frob directory name
- `description` helps the LLM understand when to use your tool
- `parameters` defines the arguments the LLM can provide
- Be descriptive - the LLM uses this to decide when/how to call your tool

### 3. main

The executable that implements your frob. Can be:

- Shell script (`#!/bin/bash`)
- Elixir script (escript or plain `elixir`-run script)
- Compiled binary
- Any executable

**Must be executable:**

```bash
chmod +x ~/.fnord/tools/my_frob/main
```

## Implementation

### Input: Environment Variables

Fnord passes data to your frob via environment variables:

|Variable|Description|Format|
|----------|-------------|--------|
|`FNORD_PROJECT`|Current project name|String|
|`FNORD_CONFIG`|Project configuration|JSON object|
|`FNORD_ARGS_JSON`|LLM-provided arguments|JSON object|

**Example shell script:**

```bash
#!/bin/bash

# Parse JSON arguments
QUERY=$(echo "$FNORD_ARGS_JSON" | jq -r '.query')
LIMIT=$(echo "$FNORD_ARGS_JSON" | jq -r '.limit // 10')

# Use project configuration
PROJECT_ROOT=$(echo "$FNORD_CONFIG" | jq -r '.root')

# Perform your task
echo "Searching $PROJECT_ROOT for: $QUERY (limit: $LIMIT)"
# ... your implementation ...
```

**Example Elixir script:**

```elixir
#!/usr/bin/env elixir

Mix.install([{:jason, "~> 1.4"}])

project = System.fetch_env!("FNORD_PROJECT")
config = System.fetch_env!("FNORD_CONFIG") |> Jason.decode!()
args = System.fetch_env!("FNORD_ARGS_JSON") |> Jason.decode!()

query = Map.fetch!(args, "query")
limit = Map.get(args, "limit", 10)

IO.puts("Searching #{project} for: #{query} (limit: #{limit})")
# ... your implementation ...
```

### Output: STDOUT

Your frob should write its results to STDOUT. Fnord captures this and provides it to the LLM as the tool's response.

**Best practices:**

- Use clear, structured output (JSON, markdown, plain text)
- Include relevant details but stay concise
- Report errors clearly
- Exit with non-zero code on failure

**Example output:**

```
Found 3 matches for "authentication":

1. auth/login.py - Login handler with JWT
2. auth/middleware.py - Authentication middleware
3. tests/auth_test.py - Auth integration tests
```

### Error Handling

**Exit codes:**

- `0` - Success
- Non-zero - Error (output is still captured)

**Error output:**

```bash
#!/bin/bash
if [ -z "$QUERY" ]; then
    echo "Error: query parameter is required"
    exit 1
fi
```

## Validation

Check your frob before use:

```bash
fnord frobs check --name my_frob
```

This validates:

- All required files exist
- JSON files are valid
- `main` is executable
- `spec.json` has required fields

## Testing

Use the `testing:` prefix in your questions to ask the LLM to test your frob:

```bash
# Verify frob is available
fnord ask -p myproject -q "testing: please confirm that the 'my_frob' tool is available to you"

# Test with specific arguments
fnord ask -p myproject -q "testing: call 'my_frob' with query='test' and report the results"
```

The LLM will call your frob and describe what happened.

## Examples

### Example 1: API Query Frob

**spec.json:**

```json
{
  "name": "api_status",
  "description": "Check the status of project deployment environments",
  "parameters": {
    "type": "object",
    "properties": {
      "environment": {
        "type": "string",
        "enum": ["dev", "staging", "production"],
        "description": "The environment to check"
      }
    },
    "required": ["environment"]
  }
}
```

**main:**

```bash
#!/bin/bash
ENV=$(echo "$FNORD_ARGS_JSON" | jq -r '.environment')
API_KEY=$(echo "$FNORD_CONFIG" | jq -r '.api_key')

curl -s -H "Authorization: Bearer $API_KEY" \
  "https://api.example.com/status/$ENV" | jq .
```

### Example 2: Custom Analysis Frob

**spec.json:**

```json
{
  "name": "complexity_check",
  "description": "Analyze code complexity for a specific file",
  "parameters": {
    "type": "object",
    "properties": {
      "file_path": {
        "type": "string",
        "description": "Relative path to file from project root"
      }
    },
    "required": ["file_path"]
  }
}
```

**main:**

```python
#!/usr/bin/env python3
import os, json, subprocess

args = json.loads(os.environ['FNORD_ARGS_JSON'])
config = json.loads(os.environ['FNORD_CONFIG'])

file_path = os.path.join(config['root'], args['file_path'])

# Run complexity analysis
result = subprocess.run(
    ['radon', 'cc', '-s', file_path],
    capture_output=True,
    text=True
)

print(result.stdout)
```

## Best Practices

1. **Clear descriptions** - Help the LLM understand when to use your frob
2. **Validate input** - Check required arguments and fail fast
3. **Concise output** - Return relevant info without overwhelming the LLM
4. **Error messages** - Make errors clear and actionable
5. **Idempotent** - Safe to call multiple times with same args
6. **Fast** - Keep execution time under a few seconds when possible
7. **No side effects** - Avoid modifying project state (read-only preferred)

## Security Considerations

**Frobs execute with your user permissions:**

- Be careful with system commands
- Validate all input from `FNORD_ARGS_JSON`
- Don't trust LLM-provided arguments blindly
- Avoid executing arbitrary code
- Use absolute paths when modifying files

**Example input validation:**

```bash
#!/bin/bash
FILE=$(echo "$FNORD_ARGS_JSON" | jq -r '.file')

# Validate file path is within project
if [[ "$FILE" == ../* ]] || [[ "$FILE" == /* ]]; then
    echo "Error: file path must be relative to project root"
    exit 1
fi
```

## Troubleshooting

### Frob not available in ask

1. Ensure the frob is enabled (global or project):
   - Global: `fnord frobs enable --name my_frob --global`
   - Project: `fnord frobs enable --name my_frob`
2. Verify frob passes validation: `fnord frobs check --name my_frob`
3. Test explicitly: `fnord ask -p myproject -q "testing: is my_frob available?"`

### Frob executes but returns nothing

1. Check `main` outputs to STDOUT (not STDERR)
2. Ensure `main` is executable (`chmod +x`)
3. Test directly: `FNORD_ARGS_JSON='{"query":"test"}' ~/.fnord/tools/my_frob/main`

### JSON parsing errors

1. Validate JSON files: `cat spec.json | jq .`
2. Check environment variable parsing in `main`
3. Use `jq` for robust JSON handling in shell scripts

## Further Reading

- [OpenAI Function Calling Documentation](https://platform.openai.com/docs/guides/function-calling)
- [Main README](../README.md)
- [Advanced MCP Configuration](mcp-advanced.md)
