# Frob example: HTTP GET

This guide shows how to create a frob that performs an HTTP GET with `curl`, automatically truncates responses larger than 5MB, and appends ` (truncated)` to the output.

- Name: `http_get`
- Behavior: GET-only; accepts a `url` and optional `headers`; truncates body to 5MB
- Output:
  - Prints the body
  - Prints `<empty body>` for successful empty responses
  - Appends ` (truncated)` if capped at the 5MB limit
- Errors: Preserves `curl` exit codes and prints a message to `stderr`

## 1) Create the frob scaffold

You can create these files manually or use `fnord frobs create` and then overwrite the files. Manual steps:

```bash
mkdir -p ~/.fnord/tools/http_get
chmod 755 ~/.fnord/tools/http_get
```

## 2) Enable the frob

You can enable the frob via settings or CLI. For example:

```bash
fnord frobs enable --name http_get --global
```
 
### Disable the frob

You can disable the frob via CLI. For example:

```bash
fnord frobs disable --name http_get --global
```

To disable for a specific project:

```bash
fnord frobs disable --name http_get --project <project_name>
```
## 3) `spec.json`

Save to: `~/.fnord/tools/http_get/spec.json`

```json
{
  "name": "http_get",
  "description": "Perform an HTTP GET request and return the body (truncated to 5MB).",
  "parameters": {
    "type": "object",
    "properties": {
      "url": {
        "type": "string",
        "description": "HTTP or HTTPS URL to fetch"
      },
      "headers": {
        "type": "object",
        "description": "Additional request headers as key/value",
        "additionalProperties": {
          "type": "string"
        }
      }
    },
    "required": ["url"]
  }
}
```

## 4) `main` (bash; make it executable)

Save to: `~/.fnord/tools/http_get/main`  
Make executable: `chmod +x ~/.fnord/tools/http_get/main`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Validate required env vars
: "${FNORD_PROJECT:?FNORD_PROJECT not set}"
: "${FNORD_CONFIG:?FNORD_CONFIG not set}"
: "${FNORD_ARGS_JSON:?FNORD_ARGS_JSON not set}"

# Dependencies
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 127; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required" >&2; exit 127; }

# Parse args
URL="$(printf '%s' "$FNORD_ARGS_JSON" | jq -er '.url')"

# Enforce GET-only and http(s) scheme
if printf '%s' "$FNORD_ARGS_JSON" | jq -e 'has("method")' >/dev/null; then
  echo "Error: Only GET is supported; do not specify a method." >&2
  exit 2
fi
SCHEME="$(printf '%s' "$URL" | awk -F:// '{print tolower($1)}')"
if [[ "$SCHEME" != "http" && "$SCHEME" != "https" ]]; then
  echo "Error: URL scheme must be http or https" >&2
  exit 2
fi

# Optional headers
HAS_HEADERS=false
if printf '%s' "$FNORD_ARGS_JSON" | jq -e 'has("headers") and (.headers | type == "object")' >/dev/null; then
  HAS_HEADERS=true
fi

# Build curl args
CURL_ARGS=(--get --fail --silent --show-error --location --max-time 30)
if $HAS_HEADERS; then
  while IFS= read -r key; do
    val="$(printf '%s' "$FNORD_ARGS_JSON" | jq -er --arg k "$key" '.headers[$k]')"
    CURL_ARGS+=(-H "${key}: ${val}")
  done < <(printf '%s' "$FNORD_ARGS_JSON" | jq -r '.headers | keys[]')
fi

# Truncate to 5MB, preserve curl exit code
LIMIT=$((5*1024*1024))
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
body_file="$tmpdir/body"

set +e
curl "${CURL_ARGS[@]}" "$URL" | dd bs=1 count=$((LIMIT+1)) of="$body_file" status=none
curl_status=${PIPESTATUS[0]}
set -e

if (( curl_status != 0 )); then
  echo "Error: HTTP request failed (curl exit $curl_status)" >&2
  exit "$curl_status"
fi

size=$(wc -c <"$body_file")
truncated=false
if (( size > LIMIT )); then
  truncated=true
fi

if (( size == 0 )); then
  echo "<empty body>"
else
  if $truncated; then
    head -c "$LIMIT" "$body_file"
    printf ' (truncated)'
  else
    cat "$body_file"
  fi
fi
```

## 5) Validate the frob

```bash
fnord frobs check --name http_get
```

## 6) Use it via `fnord ask`

- Natural language:
  ```bash
  fnord ask -q "Fetch https://example.com with http_get and return up to 5MB of the body."
  ```

- With headers:
  ```bash
  fnord ask -q "Please call http_get to GET https://httpbin.org/headers with Accept=application/json and X-Test=fnord"
  ```

Tips:
- The assistant can choose to call this tool automatically when it sees a suitable URL-shaped request.
- The frob prints `<empty body>` when the response body is empty and request succeeds.

## Safety notes

Note: If you previously configured frobs via registry.json, Fnord will migrate those settings the first time frobs are listed. After migration, registry.json is no longer used.
- GET-only by design: no `method` parameter is accepted.
- Only `http` and `https` URLs are allowed.
- Responses larger than `5MB` are truncated and marked with ` (truncated)`.
- `curl` errors are propagated and reported to `stderr`.
