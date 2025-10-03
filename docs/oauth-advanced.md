# Advanced OAuth Configuration

This guide covers advanced OAuth authentication features, troubleshooting, and manual configuration.

## Quick Reference

For basic OAuth setup, see the [main README](../README.md#oauth-authentication).

## Command-Line Options

### Using Existing Client Credentials

If you have a pre-registered client ID:

```bash
fnord config mcp add myserver --transport http --url https://api.example.com \
  --oauth --client-id YOUR_CLIENT_ID
```

With client secret (for confidential clients):

```bash
fnord config mcp add myserver --transport http --url https://api.example.com \
  --oauth --client-id YOUR_CLIENT_ID --client-secret YOUR_SECRET
```

### Custom Scopes

Specify scopes if the default (`mcp:access`) isn't appropriate:

```bash
fnord config mcp add myserver --transport http --url https://api.example.com \
  --oauth --scope custom:scope --scope another:scope
```

Multiple `--scope` flags add multiple scopes.

### What `--oauth` Does

The `--oauth` flag automatically:
- Fetches OAuth configuration from `/.well-known/oauth-authorization-server`
- Registers your client using dynamic client registration (RFC 7591) if no `client_id` provided
- Selects appropriate scopes (defaults to `mcp:access`)
- Stores the configuration in your settings

## Manual Configuration

For maximum control, you can edit `~/.fnord/settings.json` directly:

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
        "scopes": ["mcp:access"],
        "redirect_port": 8080
      }
    }
  }
}
```

### OAuth Configuration Fields

**Required:**
- `discovery_url` - OAuth discovery endpoint (RFC 8414)
- `client_id` - OAuth client identifier
- `scopes` - Array of OAuth scope strings

**Optional:**
- `client_secret` - For confidential clients (keep this secure!)
- `redirect_port` - Fixed port for loopback redirects (for exact URI matching)
- `redirect_uri` - Custom redirect URI (advanced)
- `credentials_path` - Custom path for token storage (default: `~/.fnord/credentials.json`)
- `refresh_margin` - Seconds before expiry to refresh tokens (default: 300)

## Understanding the OAuth Flow

Fnord implements OAuth 2.0 Authorization Code flow with PKCE (Proof Key for Code Exchange) for security.

### Flow Steps

1. **Discovery** (RFC 8414)
   - Fetch metadata from `/.well-known/oauth-authorization-server`
   - Extract authorization and token endpoints

2. **Registration** (RFC 7591, if needed)
   - If no `client_id` provided and server supports it
   - Register as a native app with loopback redirect
   - Obtain `client_id` (and possibly `client_secret`)

3. **Authorization** (RFC 7636)
   - Generate PKCE code verifier and challenge (S256)
   - Generate state parameter for CSRF protection
   - Build authorization URL with required parameters
   - Open browser for user consent

4. **Token Exchange**
   - Receive authorization code via loopback callback
   - Validate state parameter
   - Exchange code for tokens with PKCE verifier
   - Store tokens securely

5. **Token Refresh**
   - Monitor token expiry
   - Automatically refresh before expiration
   - Update stored credentials

### PKCE (RFC 7636)

Fnord always uses PKCE with S256 challenge method for security:
- Code verifier: 43-128 character random string
- Code challenge: Base64URL(SHA256(verifier))
- Prevents authorization code interception attacks

## Security

### Token Storage

Tokens are stored in `~/.fnord/credentials.json` with strict file permissions:
- File permissions: `0600` (owner read/write only)
- Format: JSON with server name as key
- Contains: `access_token`, `refresh_token`, `expires_at`, `token_type`, `scope`

**Never commit this file to version control!**

### Security Best Practices

1. **Use PKCE** - Fnord always enables this
2. **Loopback redirects** - Uses `http://127.0.0.1:<port>/callback` for native apps
3. **State parameter** - Validates to prevent CSRF attacks
4. **Secure storage** - Restrictive file permissions on credentials
5. **No logging** - Tokens and secrets are never logged

### Revoking Access

To revoke access:
1. Delete tokens: `rm ~/.fnord/credentials.json` (or edit to remove specific server)
2. Revoke at provider (check provider's OAuth settings)
3. Re-authenticate: `fnord config mcp login <server>`

## Token Management

### Token Refresh

Fnord automatically refreshes access tokens:
- Default refresh margin: 5 minutes (300 seconds) before expiry
- Configurable via `refresh_margin` in oauth config
- Uses refresh token from authorization flow

### Token Expiry

Check token status:
```bash
fnord config mcp status <server>
```

Shows:
- Token validity
- Expiration time
- Refresh token availability

### Manual Token Refresh

Tokens refresh automatically during operations, but you can force re-authentication:
```bash
# Remove old credentials and login again
rm ~/.fnord/credentials.json
fnord config mcp login <server>
```

## Troubleshooting

### Auto-discovery fails

**Error:** `OAuth discovery failed (404)`

**Causes:**
- Server doesn't support OAuth discovery (RFC 8414)
- Wrong discovery URL

**Solutions:**
1. Verify server supports `/.well-known/oauth-authorization-server`
2. Try OpenID Connect discovery: `/.well-known/openid-configuration`
3. Get OAuth endpoints from provider and configure manually

### Registration not available

**Error:** `OAuth registration not available`

**Causes:**
- Server requires pre-registered clients
- Dynamic registration (RFC 7591) not supported

**Solution:**
Register a client with the provider manually, then:
```bash
fnord config mcp add <name> --url <url> --oauth --client-id YOUR_CLIENT_ID
```

### Login timeout

**Error:** Connection timeout during login

**Causes:**
- Slow browser/user interaction
- Network issues
- OAuth provider delays

**Solutions:**
1. Increase timeout (default: 120s):
   ```bash
   fnord config mcp login <server> --timeout 300000
   ```
2. Check browser opened correctly
3. Complete OAuth consent promptly

### Redirect URI mismatch

**Error:** Redirect URI doesn't match registered URI

**Causes:**
- Provider requires exact URI match
- Port changed between registration and login

**Solution:**
Fnord reserves a port during registration and reuses it during login via `redirect_port`. If you're manually configuring, ensure the port in `redirect_port` matches what you registered with the provider.

### Browser shows "Connection refused"

**Causes:**
- Login command exited before sending HTTP response

**Solution:**
This should not happen in current fnord versions (fixed with 3-second delay). If it does:
1. Update fnord: `mix escript.install github sysread/fnord`
2. Report the issue

### No refresh token received

**Causes:**
- Provider doesn't support refresh tokens
- Scopes don't include offline access
- Provider configuration

**Solutions:**
1. Check if provider supports `refresh_token` grant type
2. Try adding scope: `--scope offline_access` (provider-specific)
3. Use shorter-lived sessions and re-authenticate as needed

### Authorization header not added

**Verify OAuth is configured:**
```bash
fnord config mcp list | grep oauth
```

**Check credentials exist:**
```bash
cat ~/.fnord/credentials.json | grep <server-name>
```

**Check token validity:**
```bash
fnord config mcp status <server>
```

**If token is expired:**
```bash
fnord config mcp login <server>
```

## Custom Discovery URLs

Some providers use non-standard discovery endpoints:

### OpenID Connect

If provider uses OpenID Connect instead of OAuth Authorization Server:
```json
{
  "oauth": {
    "discovery_url": "https://provider.com/.well-known/openid-configuration",
    ...
  }
}
```

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
