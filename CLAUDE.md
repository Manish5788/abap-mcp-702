# CLAUDE.md

Guidance for AI agents working on this repository.

## What this is

An MCP server written in plain ABAP, running inside SAP ECC 6.0 on NetWeaver
7.02. It speaks JSON-RPC 2.0 over HTTP POST through an ICF node. No Python
adapter, no ADT, no add-on.

It exists because SAP's own ABAP MCP server requires NetWeaver 7.31 SP04, and
every community alternative is ADT-based and therefore also 7.31+. Systems on
7.0x get nothing. That constraint is the entire reason this project exists —
every decision below follows from it.

## Non-negotiable constraints

### NetWeaver 7.02 syntax only

If it does not compile on 7.02, it does not belong here. That means **no**:

- inline declarations — `DATA(lv_x)`, `FINAL(...)`
- `VALUE #( )`, `NEW`, `CORRESPONDING #( )`
- string templates `|{ }|`
- `CONV`, `REDUCE`, `FILTER`, `COND`, `SWITCH`
- table expressions `itab[ ]`, `LINE_EXISTS( )`
- chained method calls in a single expression
- `@` escaping in SQL, or inline `INTO @DATA(...)`

Use `DATA` blocks at the top, `CONCATENATE`, `CREATE OBJECT`, classic
`SELECT ... INTO TABLE`.

**The trap that costs the most time:** `IMPORTING` parameters typed against a
DDIC field pass by reference, so lengths must match exactly. `STRING` into
`CHAR255` is a syntax error, and so is `CHAR20` into `CHAR40`. Route through a
correctly typed local:

```abap
DATA lv_err_txt TYPE zai_api_log-err_text.
lv_err_txt = ev_error.
```

Untyped literals adapt automatically and need no local.

**Two more that have bitten repeatedly:**

`CONCATENATE` drops trailing blanks from literals, so
`CONCATENATE a '   ' b INTO c` gives `ab`. Use `SEPARATED BY space` or separate
statements. This produced glued-together routine names in the skeleton output
and took two debugging cycles to find.

Offset **writes** into `STRING` or `XSTRING` are illegal. Reading
`iv_data+lv_i(1)` is fine; writing `rv_out+lv_i(1) = x` is not.

### Read-only, by construction

Every tool is a `SELECT` or a `READ REPORT`. There is no write path in this
codebase, and that absence is the design — it is what makes the server
deployable without a lengthy approval process.

**Do not add one.** Not activation, not transport operations, not object
creation, not even "just for DEV". A pull request that adds a write path will
not be merged.

### Custom namespace only

`CHECK_CUSTOM` gates every tool. Names must start with `Z` or `Y`. This is
enforced in ABAP before any tool body runs, not requested in a prompt — a
prompt rule is advice, this is a gate.

### Dependencies

Only [ajson](https://github.com/sbcgua/ajson). Do not add more. Every extra
dependency is another thing a stranger has to install before this works.

## Architecture

```
ICF node /sap/bc/mcp
  ZCL_ABAPMCP_SERVER      JSON-RPC 2.0, MCP protocol, dispatch
    ZCL_ABAPMCP_TOOLS     the four tools, namespace guard
      ZCL_ABAPMCP_STRUCTURE   static analysis and source compression
```

`ZCL_ABAPMCP_SERVER` knows about MCP and nothing about ABAP repository
internals. `ZCL_ABAPMCP_TOOLS` knows about the repository and nothing about
MCP. Keep that separation — it is what lets the tools class be called directly
from an in-system app without dragging the protocol along.

## MCP protocol notes

Three things break hand-written MCP servers. All three are handled; do not
undo them.

**Notifications must get no response.** A JSON-RPC notification has no `id`.
`notifications/initialized` is a notification. Returning a body to it leaves
the client waiting forever and the handshake never completes. The server
returns HTTP 202 with an empty body for anything lacking an `id`.

**Tool failures are not JSON-RPC errors.** A refused namespace check or a
missing object is a *successful* response carrying `isError: true` in the
result. The model then reads the message and adapts. A JSON-RPC error tells the
client the transport broke, which is a different and wrong thing.

**`input_schema` versus `inputSchema`.** The Anthropic Messages API uses
snake_case; MCP uses camelCase. `GET_TOOL_DEFS` returns the Messages API shape
and `do_tools_list` renames the key. One catalogue, two consumers.

## Source compression

The interesting part of this codebase.

A 2,800-line program is roughly 40,000 tokens and does not fit in context.
Returning its first 300 lines produces a confident answer about the
declarations — worse than useless, because it looks complete.

`ZCL_ABAPMCP_STRUCTURE` scans the **whole** object and emits a ~60-line
skeleton: tables read and written, function modules and BAPIs called, every
routine with its line range and a complexity score, and flags such as "no
AUTHORITY-CHECK anywhere". `GET_SOURCE` returns that skeleton plus the source
of the highest-scoring routines, and the caller then asks for further routines
**by name**.

Result: 3–5k tokens instead of 40k, and coverage is complete rather than
truncated.

**If you change the skeleton output format, check the routine names are
printed cleanly.** The `CONCATENATE` trailing-blank trap silently glued `FORM`
to `GET_DATA`, the model then requested `FORMGET_DATA`, the lookup failed, and
it fell back to line windows and exhausted its budget. The failure looked like
a loop problem and was a string problem.

## Logging

`ZCL_ABAPMCP_LOG` writes one row per request to `ZABAPMCP_LOG`, opened before
parsing and closed before the response is sent. This is not optional
infrastructure — it is the only debugging surface. There is no console, no
traceback, and the characteristic failure is a client that connects and then
does nothing at all.

Three rules when touching it:

**Log before parsing.** A body that fails to parse is exactly the case worth
seeing. `open` is called with the raw text before `zcl_ajson=>parse`.

**Logging must never break a request.** Every method in `ZCL_ABAPMCP_LOG`
swallows its own exceptions. A logging failure returning an error to the client
would be worse than no logging.

**Bodies are sensitive.** `REQ_BODY` holds whatever was asked, including tool
arguments. Capture is switchable via `ZABAPMCP_CFG` key `CAPTURE_BODIES` and
should be turned off once a deployment is stable.

`ZABAPMCP_LOG_VIEW` classifies rows. `NOTIFY-ANSWERED` — a notification that
received a response body — is the flag that explains most connection failures.

## Two protocol details that are easy to undo

**The JSON-RPC id must keep its type.** A client sending `{"id":1}` and
receiving `{"id":"1"}` may fail to correlate the response with its request, and
the symptom is a call that appears to hang rather than an error. ajson's `get`
always returns a string, so `copy_id` reads `get_node_type` separately and uses
`set_integer` when the node was a number. Do not simplify this back to a single
`set`.

**`check_auth` allows the call when the auth object does not exist.** That is
deliberate. Refusing until someone has done SU21 work makes the first five
minutes of every install a support question. An administrator switches gating
on by creating the object.

## Tool enablement

`IS_ENABLED` reads `ZABAPMCP_CFG` key `TOOLS_DISABLED` and is checked in two
places: `GET_TOOL_DEFS` filters the catalogue, and `EXECUTE` refuses at the
top. Both are needed — a client that cached the tool list before a tool was
switched off would otherwise still be able to call it.

When adding a tool, nothing special is required; `IS_ENABLED` works from the
tool name and the filter is generic.

## Testing

There is no unit test framework here — it needs a live SAP system.

Minimum manual test before any commit:

1. `initialize` returns capabilities and `serverInfo`
2. `tools/list` returns four tools with `inputSchema` (camelCase)
3. `tools/call` on `sap_get_ddic` with a `Z` table returns fields
4. `tools/call` on `sap_get_ddic` with `MARA` returns `isError: true`
5. `sap_get_source` on an object over 400 lines returns `mode: STRUCTURE`
6. A follow-up call with `routine` set to a name from that skeleton returns
   `mode: ROUTINE` and real source
7. `notifications/initialized` returns HTTP 202 with an empty body
8. A numeric request id comes back numeric, not quoted
9. A GET in a browser returns the plain-text info page

Test 6 is the one that regresses most often. Test 7 is the one that silently
breaks client connections.

After any change, run `ZABAPMCP_LOG_VIEW` with problems only ticked. An empty
result is the pass condition.

## When adding a tool

1. Add the method to `ZCL_ABAPMCP_TOOLS` private section
2. Add a `WHEN` branch in `EXECUTE`, **with the `CHECK_CUSTOM` guard**
3. Add the definition to `GET_TOOL_DEFS` — watch the commas, every tool object
   ends `}},` except the last which ends `}}` before the closing `]`
4. Write the description to say what the tool returns **and what it does not**.
   Overlapping descriptions degrade the model's tool selection more than tool
   count does. `sap_search_objects` explicitly says it cannot find usage and
   points at `sap_where_used`, because without that the model kept reaching for
   the wrong one.

Keep the total under about ten tools. Beyond that, selection accuracy falls off
and it is better to consolidate related tools behind a `mode` parameter.

## Style

- Comments explain *why*, not *what*. The reader can see what the code does.
- Where a decision looks odd, say why in a comment — most of the odd-looking
  code here is working around a 7.02 constraint and will be "fixed" by someone
  otherwise.
- No emoji, no decorative headers.
- Sentence case in prose and messages.
- Error messages are for a model to read and act on. Say what went wrong *and*
  what to do instead: "Routine not found. Use a name from the routines list in
  the skeleton" is useful; "not found" is not.
