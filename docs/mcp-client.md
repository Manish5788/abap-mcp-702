# Connecting an MCP client

The server speaks JSON-RPC 2.0 over HTTP POST. Any MCP client that supports
HTTP transport connects directly — no adapter needed.

---

## Verify the server first

Before touching a client, confirm the endpoint answers. Replace host, port and
client for your system.

```bash
curl -k -u YOURUSER \
  -X POST 'https://sapdev.example.com:44300/sap/bc/mcp?sap-client=100' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

Expected:

```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": { "tools": { "listChanged": false } },
    "serverInfo": { "name": "abap-mcp-702", "version": "0.2.0" }
  }
}
```

If that works, everything else is dispatch. Then check the catalogue:

```bash
curl -k -u YOURUSER \
  -X POST 'https://sapdev.example.com:44300/sap/bc/mcp?sap-client=100' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

And one real call:

```bash
curl -k -u YOURUSER \
  -X POST 'https://sapdev.example.com:44300/sap/bc/mcp?sap-client=100' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sap_get_ddic","arguments":{"name":"ZYOURTABLE"}}}'
```

---

## Claude Desktop

Claude Desktop currently launches MCP servers as local processes over stdio, so
an HTTP endpoint needs a bridge. `mcp-remote` does this without any custom code:

```json
{
  "mcpServers": {
    "sap-ecc": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "https://sapdev.example.com:44300/sap/bc/mcp?sap-client=100",
        "--header", "Authorization: Basic BASE64_USER_COLON_PASSWORD"
      ]
    }
  }
}
```

Generate the header value with:

```bash
printf 'YOURUSER:YOURPASS' | base64
```

Put that file at `~/Library/Application Support/Claude/claude_desktop_config.json`
on macOS, or `%APPDATA%\Claude\claude_desktop_config.json` on Windows, then
restart Claude Desktop.

**Self-signed certificate?** Add `"--allow-http"` only if you are on plain HTTP
inside a trusted network, or install the SAP certificate into your OS trust
store. Do not disable TLS verification as a habit.

---

## Claude Code

```bash
claude mcp add --transport http sap-ecc \
  'https://sapdev.example.com:44300/sap/bc/mcp?sap-client=100' \
  --header 'Authorization: Basic BASE64_USER_COLON_PASSWORD'
```

Then `claude mcp list` should show it connected, and the tools of your tool
groups appear in the session. Call `sap_whoami` first: it shows system,
client, user and which of your own authorizations pass.

---

## Other clients

Anything supporting MCP over HTTP works the same way — point it at the URL and
supply basic auth. The server is stateless, so there is no session to manage.

---

## stdio-only clients

A few clients still launch an MCP server as a local child process and speak to
it over stdio rather than HTTP. For those, `sap_mcp_bridge.py` in the repo root
is a minimal stdlib-only shim: it reads newline-delimited JSON-RPC from stdin,
forwards each message to the ICF node, and writes the reply back to stdout.

```json
{
  "mcpServers": {
    "sap-ecc": {
      "command": "python",
      "args": ["/path/to/abap-mcp-702/sap_mcp_bridge.py"],
      "env": {
        "SAP_MCP_URL": "https://sapdev.example.com:44300/sap/bc/mcp?sap-client=100",
        "SAP_MCP_USER": "YOURUSER",
        "SAP_MCP_PASSWORD": "YOURPASS"
      }
    }
  }
}
```

Set `SAP_MCP_AUTH` to a full header value instead of `SAP_MCP_USER` /
`SAP_MCP_PASSWORD` for token auth, `SAP_MCP_INSECURE=1` to accept a self-signed
certificate on a trusted network, and `SAP_MCP_DEBUG=1` to trace requests to
stderr. Prefer a native HTTP client where you have one — the bridge is only for
clients that cannot do HTTP at all.

When SAP refuses the logon or the channel (wrong password, locked user, no
`Z_AI_CHAN` = `MCP`, no network), the bridge still completes the MCP handshake
and offers one tool, `sap_access_check`, whose description says what is wrong
and what to ask for - instead of the client timing out silently. Refusals from
`ZCL_AI_AUTH` get plain-language advice added.

---

## Authentication

The server uses whatever the ICF node is configured for. Basic auth against a
normal SAP user is the simplest and means **the tools run under that person's
own authorizations** — they see exactly what they could already open in SE38.

That is deliberate. A shared technical user would be easier to configure and
much worse: it would decouple what the agent can read from what the person
asking is allowed to read.

For a shared or team deployment, configure the ICF node for whatever your
landscape already uses — SSO, X.509, or SAML — rather than distributing
passwords.

---

## Troubleshooting

**Nothing comes back, or the client hangs on connect.**
The handshake is failing. Check `notifications/initialized` returns HTTP 202
with an empty body — returning a JSON body to a notification is the single most
common cause, and the client waits forever rather than erroring.

**HTTP 401.**
ICF node authentication. Check SICF → your node → Logon Data.

**HTTP 403 "HTTPS is required".**
You called the plain-HTTP port. Use HTTPS, or for a first test on a closed
network set `ZABAPMCP_CFG` key `REQUIRE_SSL` = `OFF`.

**Only some tools appear, or a call says "not authorised".**
`ZCL_AI_AUTH` filters `tools/list` by the caller's tool groups. Run
`ZABAPMCP_LOG_VIEW` and look at the `AUTH` rows, or SU53 right after the call.

**HTTP 404.**
Node not activated. In SICF, right-click the node and choose Activate Service.

**"Method not found" for `resources/list` or `prompts/list`.**
Expected. This server implements tools only, and advertises only tools in its
capabilities. A well-behaved client will not call those; one that does gets a
clean JSON-RPC error rather than a broken partial answer.

**Every object read is refused.**
The namespace guard is working. Only `Z` and `Y` objects are readable. Try one
of your own custom objects.

**The model asks for the same source repeatedly.**
It is not using the routine names from the skeleton. Check that the skeleton's
routine list prints names cleanly — a `CONCATENATE` bug once glued the routine
kind to its name, producing `FORMGET_DATA` instead of `GET_DATA`, and every
lookup then failed.
