# Advanced OAuth Configuration

This guide covers the current OAuth support for MCP servers: what the CLI exposes, what fnord stores, and where manual configuration is still useful.

## Quick reference

For the basic flow, see the [main README](../README.md#oauth-authentication).

## CLI workflow

### Add an OAuth-enabled MCP server

If you already have a client ID:

```bash
fnord config mcp add myserver --transport http --url https://api.example.com \
  --oauth --client-id YOUR_CLIENT_ID
```

If the provider also gave you a client secret:

```bash
fnord config mcp add myserver --transport http --url https://api.example.com \
  --oauth --client-id YOUR_CLIENT_ID --client-secret YOUR_SECRET
```

If you need non-default scopes:

```bash
fnord config mcp add myserver --transport http --url https://api.example.com \
  --oauth --scope custom:scope --scope another:scope
```

Multiple `--scope` flags add multiple scopes.
If you do not pass any scopes, fnord defaults to `mcp:access`.

### Log in

OAuth login is a separate command:

```bash
fnord config mcp login myserver
```

The login command takes the server name plus an optional callback timeout:

```bash
fnord config mcp login myserver --timeout 300000
```

### Check status

```bash
fnord config mcp status myserver
```

## What `--oauth` does

When you run `fnord config mcp add ... --oauth`, fnord:

- Discovers OAuth endpoints from the provider metadata
- Registers a client if the server supports dynamic client registration and you did not provide a client ID
- Stores the OAuth configuration with the MCP server settings
- Leaves the actual browser login flow for `fnord config mcp login`

## Manual configuration

Most users should prefer the CLI.
Manual edits are still possible if you need to inspect or repair the stored config.

A typical OAuth server entry looks like this:

```json
{
  "mcp_servers": {
    "myserver": {
      "transport": "http",
      "base_url": "https://api.example.com",
      "oauth": {
        "discovery_url": "https://api.example.com/.well-known/oauth-authorization-server",
        "client_id": "your-client-id",
        "client_secret": "optional-secret",
        "redirect_uri": "http://localhost:8080/callback",
        "scopes": ["mcp:access"]
      }
    }
  }
}
```

### OAuth configuration fields

Current config shape:

- `discovery_url` - OAuth discovery endpoint
- `client_id` - OAuth client identifier
- `client_secret` - optional secret for confidential clients
- `redirect_uri` - loopback callback URI used during login
- `scopes` - list of scopes to request

Fnord stores credentials separately from this config.
The credentials store is `~/.fnord/credentials.json`.

## Understanding the flow

Fnord uses OAuth 2.0 Authorization Code flow with PKCE for MCP login.
At a high level:

1. **Discovery**
   - Fetch provider metadata
   - Resolve authorization, token, and registration endpoints

2. **Registration**
   - If needed, register a native client with a loopback redirect URI

3. **Authorization**
   - Generate a PKCE verifier and challenge
   - Generate a state value
   - Open the browser to the provider's authorization page

4. **Token exchange**
   - Receive the callback on the loopback server
   - Validate state
   - Exchange the code for tokens
   - Store tokens in the credentials store

5. **Refresh**
   - Reuse the refresh token when the provider issued one
   - Persist updated credentials after refresh

### Resource indicators (RFC 8707)

The MCP authorization spec requires clients to identify which server a
token is for. Fnord sends the server's configured `base_url` as the
`resource` parameter on the authorization request, the token exchange,
and refreshes. Servers that enforce this (e.g. Linear) reject flows
that omit it; servers that predate it ignore the extra parameter.

### PKCE

Fnord always uses PKCE with the S256 challenge method.
The exact verifier representation is an implementation detail; the important contract is that fnord generates a verifier, derives the S256 challenge from it, and sends both sides of the flow correctly.

## Security

### Token storage

Tokens are stored in `~/.fnord/credentials.json`.
That file is separate from `~/.fnord/settings.json`, which holds the MCP server config.

Never commit either file to version control.

### Security properties

Fnord's OAuth flow relies on:

1. PKCE
2. Loopback redirects for native-app login
3. State validation
4. Local credential storage

## Token management

### Token refresh

Fnord refreshes access tokens when it has enough information to do so.
Whether that succeeds depends on the provider returning a refresh token and supporting refresh for the granted client/scopes.

### Token expiry and status

Check token status with:

```bash
fnord config mcp status myserver
```

### Re-authentication

If you need to start over:

```bash
rm ~/.fnord/credentials.json
fnord config mcp login myserver
```

## Troubleshooting

### Discovery fails

Usual causes:

- The server does not expose OAuth discovery metadata
- The configured discovery URL is wrong

Usual fixes:

1. Verify the provider supports `/.well-known/oauth-authorization-server`
2. Try an OpenID Connect discovery document if the provider uses that shape
3. Re-check the stored server config

### Dynamic registration is unavailable

Some providers require a pre-registered client.
In that case, register a client with the provider and then add the MCP server with `--client-id` and, if required, `--client-secret`.

### Login times out

If browser approval takes too long, rerun login with a larger timeout:

```bash
fnord config mcp login myserver --timeout 300000
```

The timeout is passed explicitly. Do not rely on a documented default here.

### Redirect URI mismatch

Fnord's current default loopback redirect URI is `http://localhost:8080/callback`.
If the provider requires an exact match, make sure the registered client uses the same URI.

### No refresh token received

Common reasons:

- The provider does not issue refresh tokens for this client
- The provider expects an extra scope such as `offline_access`
- The provider requires different client registration settings

## Custom discovery URLs

Some providers use non-standard discovery endpoints.
If your provider exposes OpenID Connect metadata instead of the OAuth authorization-server document, point discovery at that URL.

### Custom Endpoints

If provider doesn't support discovery, you'll need to manually configure endpoints (not currently supported by fnord CLI - file a feature request).

## RFC References

Fnord implements these OAuth RFCs:

- [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749) - OAuth 2.0 Authorization Framework
- [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636) - PKCE (Proof Key for Code Exchange)
- [RFC 7591](https://www.rfc-editor.org/rfc/rfc7591) - Dynamic Client Registration
- [RFC 8414](https://www.rfc-editor.org/rfc/rfc8414) - OAuth 2.0 Authorization Server Metadata

## Further Reading

- [OAuth 2.0 Simplified](https://www.oauth.com/)
- [Advanced MCP Configuration](mcp-advanced.md)
- [Hermes MCP Documentation](https://hexdocs.pm/hermes_mcp/)
