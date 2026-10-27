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

Every request gets an answer the user can read, never a silent timeout. When
SAP refuses the connection itself (wrong password, locked user, missing
channel authorization, no network), the bridge still completes the MCP
handshake and offers a single tool, sap_access_check, whose description and
the server instructions say what is wrong and what to ask for. Refusals from
SAP's authorization checks (ZCL_AI_AUTH) get plain-language advice added.

Configuration is by environment variable:

    SAP_MCP_URL        full URL of the ICF node, incl. ?sap-client=NNN  (required)
    SAP_MCP_USER       SAP user for basic auth
    SAP_MCP_PASSWORD   password for that user
    SAP_MCP_AUTH       complete Authorization header value; overrides USER/PASSWORD
                       e.g. "Basic dXNlcjpwYXNz" or "Bearer <token>"
    SAP_MCP_TIMEOUT    per-request timeout in seconds (default 30)
    SAP_MCP_INIT_TIMEOUT  timeout for initialize/ping in seconds (default 20) -
                       must stay below the client's handshake limit (30s in
                       Claude Code) or the bridge's own error arrives too late
    SAP_MCP_INSECURE   "1" to skip TLS certificate verification (self-signed dev only)
    SAP_MCP_DEBUG      "1" to log each request/response to stderr

Nothing is ever printed to stdout except JSON-RPC replies; diagnostics go to
stderr so they cannot corrupt the protocol stream.
"""

import base64
import json
import os
import re
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_PATH = "/sap/bc/mcp"
BRIDGE_VERSION = "1.2.0"
DEFAULT_PROTOCOL = "2025-06-18"

# The one tool the bridge answers itself.
ACCESS_TOOL = "sap_access_check"

SU53_HINT = ("To see exactly which check failed, run transaction SU53 in SAP GUI "
             "right after the refused call and send a screenshot to SAP security.")

# Refusal texts of ZCL_AI_AUTH -> what the user should do. First match wins;
# {0} is the first group of the pattern. Object setup: docs/security.md.
_AUTH_ADVICE = (
    (r"channel MCP \(Z_AI_CHAN\)",
     "Your SAP user is not allowed to use the AI tools from Claude (channel MCP). "
     "Ask SAP security for a role with Z_AI_CHAN = MCP."),
    (r"channel (\S+) \(Z_AI_CHAN\)",
     "Your SAP user is not allowed to use the AI tools through channel {0}. "
     "Ask SAP security for the AI role that grants it."),
    (r"not assigned to a tool group \(ZAI_TOOL_GRP\)",
     "This tool is not released for use yet (it has no tool group in ZAI_TOOL_GRP). "
     "A role cannot fix this - contact the AI tool owners."),
    (r"tool group (\S+) \(Z_AI_TOOL\)",
     "Your AI role does not include tool group {0} (Z_AI_TOOL). Ask SAP security for it."),
    (r"Package of .* not found",
     "The object was not found in any package - check the object name."),
    (r"package (\S+) \(Z_AI_SCOPE DEVCLASS\)",
     "Your AI role does not cover code in package {0} (Z_AI_SCOPE DEVCLASS). "
     "Ask SAP security if you need to read it."),
    (r"Z_AI_SCOPE ANY",
     "You may see only your own transport requests and dumps. Other users' need "
     "Z_AI_SCOPE = ANY (usually technical leads)."),
    (r"Z_AI_SCOPE OWN",
     "Your AI role does not include your own transport requests and dumps "
     "(Z_AI_SCOPE OWN). Ask SAP security for the role of your persona."),
    (r"\(Z_AI_ADM\)",
     "Administration functions are for the AI tool owners only (Z_AI_ADM)."),
    (r"ZMCP_USE",
     "SAP checks the single authorization ZMCP_USE (activity 03) for these tools "
     "(AUTH_MODE LEGACY or DUAL). Ask SAP security for it, or for the Z_AI_* objects."),
)

_REFUSAL_RE = re.compile(r"not authori[sz]ed|no authori[sz]ation|not allowed", re.I)


def _env_bool(name):
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


def _normalise_url(url):
    """Accept a bare host URL as well as the full ICF node URL.

    Users of the Claude Desktop settings form often paste just
    https://host:port; posting JSON-RPC there gets an HTML 404 logon page and
    the handshake fails. With no path given, the node path is appended.
    """
    parts = urllib.parse.urlsplit(url)
    if parts.path in ("", "/"):
        parts = parts._replace(path=DEFAULT_PATH)
    return urllib.parse.urlunsplit(parts)


def _float_env(name, default):
    try:
        return float(os.environ.get(name, str(default)))
    except ValueError:
        return float(default)


def _load_config():
    url = os.environ.get("SAP_MCP_URL", "").strip()
    if not url:
        sys.exit(
            "sap_mcp_bridge: SAP_MCP_URL is not set. Point it at the ICF node, "
            "for example https://host:44300/sap/bc/mcp?sap-client=100"
        )
    url = _normalise_url(url)

    auth = os.environ.get("SAP_MCP_AUTH", "").strip()
    if not auth:
        user = os.environ.get("SAP_MCP_USER", "").strip()
        password = os.environ.get("SAP_MCP_PASSWORD", "")
        if user:
            raw = "{0}:{1}".format(user, password).encode("utf-8")
            auth = "Basic " + base64.b64encode(raw).decode("ascii")

    ssl_ctx = None
    if url.lower().startswith("https"):
        ssl_ctx = ssl.create_default_context()
        if _env_bool("SAP_MCP_INSECURE"):
            ssl_ctx.check_hostname = False
            ssl_ctx.verify_mode = ssl.CERT_NONE

    return {
        "url": url,
        "auth": auth,
        "timeout": _float_env("SAP_MCP_TIMEOUT", 30),
        "init_timeout": _float_env("SAP_MCP_INIT_TIMEOUT", 20),
        "ssl_ctx": ssl_ctx,
        "debug": _env_bool("SAP_MCP_DEBUG"),
    }


def _log(cfg, message):
    if cfg["debug"]:
        sys.stderr.write("sap_mcp_bridge: " + message + "\n")
        sys.stderr.flush()


# --- JSON-RPC replies -------------------------------------------------------

def _dump(obj):
    return json.dumps(obj, separators=(",", ":"))


def _result(request_id, result):
    return _dump({"jsonrpc": "2.0", "id": request_id, "result": result})


def _error(request_id, code, message):
    return _dump({"jsonrpc": "2.0", "id": request_id,
                  "error": {"code": code, "message": message}})


def _tool_text(request_id, text, is_error):
    return _result(request_id, {"content": [{"type": "text", "text": text}],
                                "isError": is_error})


# --- advice -----------------------------------------------------------------

def _advice(reason):
    """Plain-language next step for an SAP refusal text, or ''."""
    for pattern, advice in _AUTH_ADVICE:
        match = re.search(pattern, reason, re.I)
        if match:
            return advice.format(*match.groups()) + " " + SU53_HINT
    if _REFUSAL_RE.search(reason):
        return SU53_HINT
    return ""


def _with_advice(reason):
    advice = _advice(reason)
    return reason + ("\n\nWhat to do: " + advice if advice else "")


# --- HTTP -------------------------------------------------------------------

# Words SAP's logon page and logon error texts use (EN/DE).
_LOGON_MARKERS = ("logon", "log on", "anmeld", "password", "kennwort",
                  "sap-system-login", "user is locked", "benutzer ist gesperrt")

_LOGON_ADVICE = ("Check the SAP user and password in the extension settings (Claude "
                 "Desktop: Settings > Extensions > SAP ECC ABAP MCP > Configure; Claude "
                 "Code: SAP_MCP_USER / SAP_MCP_PASSWORD) and that the user is not "
                 "locked - try logging on to the same client in SAP GUI.")


def _excerpt(body, limit=300):
    """Readable one-line excerpt of an SAP reply body, HTML tags removed."""
    text = body.decode("utf-8", "replace")
    text = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def _looks_like_logon(body):
    lower = body.decode("utf-8", "replace").lower()
    return any(marker in lower for marker in _LOGON_MARKERS)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Surface redirects as HTTPError instead of following them.

    SAP answers a failed or missing logon with a redirect to its HTML logon
    page; following it turns an auth failure into a 200 with HTML.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _post(cfg, payload_bytes, timeout):
    req = urllib.request.Request(cfg["url"], data=payload_bytes, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if cfg["auth"]:
        req.add_header("Authorization", cfg["auth"])

    handlers = [_NoRedirect()]
    if cfg["ssl_ctx"] is not None:
        handlers.append(urllib.request.HTTPSHandler(context=cfg["ssl_ctx"]))
    opener = urllib.request.build_opener(*handlers)

    with opener.open(req, timeout=timeout) as response:
        return response.status, response.headers.get("Content-Type", ""), response.read()


def _jsonrpc_error(text):
    """Return the error object of a JSON-RPC error reply, else None."""
    try:
        obj = json.loads(text)
    except ValueError:
        return None
    if isinstance(obj, dict) and isinstance(obj.get("error"), dict):
        return obj["error"]
    return None


def _http_error_message(code, body):
    hints = {
        401: "SAP rejected the logon. " + _LOGON_ADVICE,
        403: "the SAP user lacks authorization for the ICF node. " + SU53_HINT,
        404: "check that the URL ends in /sap/bc/mcp?sap-client=NNN and that "
             "the node is active in SICF",
        500: "the SAP handler failed - look for a short dump in ST22",
        503: "the ICF service or the work processes are unavailable - check "
             "SICF and SM50",
    }
    message = "SAP returned HTTP {0}".format(code)
    if code in (301, 302, 303, 307, 308):
        message += " (redirect to the logon page) - SAP rejected the logon. " + _LOGON_ADVICE
    elif code in hints:
        message += " - " + hints[code]
    excerpt = _excerpt(body)
    if excerpt:
        message += "\nSAP said: " + excerpt
    return message


def _forward(cfg, payload_bytes, timeout):
    """POST one message to SAP.

    Returns (reply, None, None) on success - reply is the parsed JSON-RPC
    object, or None when SAP sent nothing (a notification's answer) - or
    (None, code, message) when SAP failed or refused, message readable by
    the user.
    """
    try:
        status, content_type, body = _post(cfg, payload_bytes, timeout)
    except urllib.error.HTTPError as exc:
        body = b""
        try:
            body = exc.read()
        except Exception:
            pass
        _log(cfg, "HTTP {0} from SAP: {1}".format(
            exc.code, body.decode("utf-8", "replace")[:500]))
        sap_error = _jsonrpc_error(body.decode("utf-8", "replace"))
        if sap_error is not None:
            # SAP sends "id":null for errors raised before it parsed the
            # request (e.g. the Z_AI_CHAN check); the caller answers under the
            # request's own id, so nothing is left for the client to drop.
            reason = sap_error.get("message", "no message")
            return None, sap_error.get("code", -32000), _with_advice(
                "SAP refused the request (HTTP {0}): {1}".format(exc.code, reason))
        return None, -32000, _http_error_message(exc.code, body)
    except Exception as exc:  # URLError, socket timeout, SSL, ...
        _log(cfg, "request failed: {0}".format(exc))
        reason = getattr(exc, "reason", exc)
        if isinstance(reason, (socket.timeout, TimeoutError)):
            message = ("SAP did not answer within {0:g}s - not an authorization "
                       "error. The request may be too large (narrow it) or the "
                       "work processes busy; check SM50 and ST22 for TIME_OUT."
                       ).format(timeout)
        elif isinstance(reason, ssl.SSLError):
            message = "TLS handshake with SAP failed: {0}".format(reason)
        else:
            message = ("Cannot reach SAP: {0}. Check the network or VPN connection "
                       "and the SAP MCP URL.").format(reason)
        return None, -32001, message

    text = body.decode("utf-8", "replace").strip()
    _log(cfg, "HTTP {0}, {1}, {2} bytes".format(status, content_type, len(body)))
    if not text:
        return None, None, None

    # Anything that is not JSON would be dropped by the client, which then
    # waits into a timeout - turn it into an error the user can read.
    try:
        reply = json.loads(text)
    except ValueError:
        if _looks_like_logon(body):
            message = "SAP returned its logon page instead of an answer. " + _LOGON_ADVICE
        else:
            message = "SAP returned a non-JSON reply (HTTP {0}, {1})".format(
                status, content_type or "no content type")
        excerpt = _excerpt(body)
        if excerpt:
            message += "\nSAP said: " + excerpt
        return None, -32002, message

    if isinstance(reply, dict) and isinstance(reply.get("error"), dict):
        error = reply["error"]
        return None, error.get("code", -32000), _with_advice(
            error.get("message", "SAP returned an error without a message"))
    return reply, None, None


# --- MCP handling -----------------------------------------------------------

def _access_tool(problem):
    description = ("Check whether SAP accepts your user for the SAP tools. "
                   "The SAP tools are unavailable because SAP refused the "
                   "connection: " + problem)
    return {
        "name": ACCESS_TOOL,
        "description": description,
        "inputSchema": {"type": "object", "properties": {}},
    }


def _fallback_initialize(request_id, params, problem):
    """Complete the handshake locally so the user sees why SAP refused."""
    version = DEFAULT_PROTOCOL
    if isinstance(params, dict) and params.get("protocolVersion"):
        version = params["protocolVersion"]
    instructions = (
        "SAP refused this connection, so no SAP tools are available. Tell the "
        "user the reason and what to do, in plain words:\n" + problem +
        "\n\nOnce it is fixed, the user can call " + ACCESS_TOOL + " to check, "
        "then restart Claude (or re-enable the extension) to load the SAP tools.")
    return _result(request_id, {
        "protocolVersion": version,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "sap_mcp_abap-bridge", "version": BRIDGE_VERSION},
        "instructions": instructions,
    })


def _access_check(cfg, request_id):
    probe = _dump({"jsonrpc": "2.0", "id": "access-check", "method": "tools/list"})
    reply, _code, message = _forward(cfg, probe.encode("utf-8"), cfg["init_timeout"])
    if message is not None:
        return _tool_text(request_id, "SAP still refuses access.\n\n" + message, True)
    tools = []
    if isinstance(reply, dict) and isinstance(reply.get("result"), dict):
        tools = reply["result"].get("tools") or []
    return _tool_text(
        request_id,
        "SAP accepts your user: {0} SAP tools are available to you. Restart Claude "
        "(or turn the extension off and on) to load them.".format(len(tools)),
        False)


def _add_advice_to_tool_result(reply):
    """Append advice to an isError tool result that is an SAP refusal."""
    result = reply.get("result")
    if not isinstance(result, dict) or not result.get("isError"):
        return
    for item in result.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "text":
            advice = _advice(item.get("text", ""))
            if advice:
                item["text"] = item["text"] + "\n\nWhat to do: " + advice
                return


def _handle(cfg, line_bytes):
    """Forward one JSON-RPC message and return the reply text, or None."""
    try:
        msg = json.loads(line_bytes.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        msg = None
    if not isinstance(msg, dict):
        msg = {}
    request_id = msg.get("id")
    method = msg.get("method")
    params = msg.get("params")
    is_notification = request_id is None

    if method == "tools/call" and isinstance(params, dict) \
            and params.get("name") == ACCESS_TOOL:
        return _access_check(cfg, request_id)

    timeout = cfg["init_timeout"] if method in ("initialize", "ping") else cfg["timeout"]
    reply, code, problem = _forward(cfg, line_bytes, timeout)

    if is_notification:
        return None

    if problem is None:
        if reply is None:
            return _error(request_id, -32002, "SAP returned an empty reply")
        if method == "tools/call":
            _add_advice_to_tool_result(reply)
        reply["id"] = request_id
        return _dump(reply)

    # SAP failed or refused. The handshake and the tool list are answered
    # locally, so the client shows a connected server whose one tool explains
    # the problem, instead of a server that "failed to connect".
    if method == "initialize":
        return _fallback_initialize(request_id, params, problem)
    if method == "tools/list":
        return _result(request_id, {"tools": [_access_tool(problem)]})
    if method == "ping":
        return _result(request_id, {})
    if method == "tools/call":
        return _tool_text(request_id, problem, True)
    return _error(request_id, code or -32000, problem)


def main():
    cfg = _load_config()
    _log(cfg, "bridge {0} forwarding to {1}".format(BRIDGE_VERSION, cfg["url"]))

    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    for raw in stdin:
        # Some shells prefix piped input with a UTF-8 BOM.
        line = raw.strip().lstrip(b"\xef\xbb\xbf")
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
