#!/usr/bin/env python3
"""stdio -> HTTP bridge for the abap-mcp-702 server.

Most MCP clients speak HTTP and connect to the ICF node directly - they do not
need this file. It exists only for clients that launch an MCP server as a local
process and talk to it over stdio (some editor integrations, older Claude
Desktop builds). This script is that local process: it reads newline-delimited
JSON-RPC from stdin, forwards each message to the SAP endpoint over HTTP POST,
and writes the reply back to stdout.

Transport framing is the MCP stdio convention: one JSON-RPC message per line,
no embedded newlines, nothing else on the stream. (The previous version of this
file used LSP-style "Content-Length" headers, which MCP does not use - that is
why it never actually connected.)

Configuration is by environment variable:

    SAP_MCP_URL        full URL of the ICF node, incl. ?sap-client=NNN  (required)
    SAP_MCP_USER       SAP user for basic auth
    SAP_MCP_PASSWORD   password for that user
    SAP_MCP_AUTH       complete Authorization header value; overrides USER/PASSWORD
                       e.g. "Basic dXNlcjpwYXNz" or "Bearer <token>"
    SAP_MCP_TIMEOUT    per-request timeout in seconds (default 30)
    SAP_MCP_INSECURE   "1" to skip TLS certificate verification (self-signed dev only)
    SAP_MCP_DEBUG      "1" to log each request/response to stderr

Nothing is ever printed to stdout except JSON-RPC replies; diagnostics go to
stderr so they cannot corrupt the protocol stream.
"""

import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.request


def _env_bool(name):
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


def _load_config():
    url = os.environ.get("SAP_MCP_URL", "").strip()
    if not url:
        sys.exit(
            "sap_mcp_bridge: SAP_MCP_URL is not set. Point it at the ICF node, "
            "for example https://host:44300/sap/bc/mcp?sap-client=100"
        )

    auth = os.environ.get("SAP_MCP_AUTH", "").strip()
    if not auth:
        user = os.environ.get("SAP_MCP_USER", "").strip()
        password = os.environ.get("SAP_MCP_PASSWORD", "")
        if user:
            raw = "{0}:{1}".format(user, password).encode("utf-8")
            auth = "Basic " + base64.b64encode(raw).decode("ascii")

    try:
        timeout = float(os.environ.get("SAP_MCP_TIMEOUT", "30"))
    except ValueError:
        timeout = 30.0

    ssl_ctx = None
    if url.lower().startswith("https"):
        ssl_ctx = ssl.create_default_context()
        if _env_bool("SAP_MCP_INSECURE"):
            ssl_ctx.check_hostname = False
            ssl_ctx.verify_mode = ssl.CERT_NONE

    return {
        "url": url,
        "auth": auth,
        "timeout": timeout,
        "ssl_ctx": ssl_ctx,
        "debug": _env_bool("SAP_MCP_DEBUG"),
    }


def _log(cfg, message):
    if cfg["debug"]:
        sys.stderr.write("sap_mcp_bridge: " + message + "\n")
        sys.stderr.flush()


def _request_id(payload_bytes):
    """Return the JSON-RPC id if present, else None (a notification)."""
    try:
        obj = json.loads(payload_bytes.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if isinstance(obj, dict):
        return obj.get("id")
    return None


def _error_reply(request_id, code, message):
    return json.dumps(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message},
        },
        separators=(",", ":"),
    )


def _post(cfg, payload_bytes):
    req = urllib.request.Request(cfg["url"], data=payload_bytes, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if cfg["auth"]:
        req.add_header("Authorization", cfg["auth"])

    kwargs = {"timeout": cfg["timeout"]}
    if cfg["ssl_ctx"] is not None:
        kwargs["context"] = cfg["ssl_ctx"]

    with urllib.request.urlopen(req, **kwargs) as response:
        return response.status, response.read()


def _handle(cfg, line_bytes):
    """Forward one JSON-RPC message and return the reply text, or None."""
    request_id = _request_id(line_bytes)
    is_notification = request_id is None

    try:
        status, body = _post(cfg, line_bytes)
    except urllib.error.HTTPError as exc:
        body = b""
        try:
            body = exc.read()
        except Exception:
            pass
        text = body.decode("utf-8", "replace").strip()
        _log(cfg, "HTTP {0} from SAP: {1}".format(exc.code, text[:500]))
        if is_notification:
            return None
        # If SAP already produced a JSON-RPC error body, pass it through untouched.
        if text.startswith("{") and '"jsonrpc"' in text:
            return text.replace("\n", " ").replace("\r", " ")
        return _error_reply(
            request_id, -32000, "SAP returned HTTP {0}".format(exc.code)
        )
    except Exception as exc:  # URLError, socket timeout, SSL, ...
        _log(cfg, "request failed: {0}".format(exc))
        if is_notification:
            return None
        return _error_reply(request_id, -32001, "SAP request failed: {0}".format(exc))

    text = body.decode("utf-8", "replace").strip()
    _log(cfg, "HTTP {0}, {1} bytes".format(status, len(body)))

    # Notifications (and the server's 202/empty answer to them) produce no reply.
    if is_notification or not text:
        return None

    # Guard the stdio framing: a reply must be exactly one line.
    return text.replace("\n", " ").replace("\r", " ")


def main():
    cfg = _load_config()
    _log(cfg, "forwarding to {0}".format(cfg["url"]))

    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    for raw in stdin:
        line = raw.strip()
        if not line:
            continue
        reply = _handle(cfg, line)
        if reply is None:
            continue
        try:
            stdout.write(reply.encode("utf-8") + b"\n")
            stdout.flush()
        except BrokenPipeError:
            break

    _log(cfg, "stdin closed, exiting")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
