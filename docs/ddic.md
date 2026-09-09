# DDIC objects

Two tables, both created in SE11. Neither holds business data.

---

## ZABAPMCP_LOG — request log

One row per HTTP request to the MCP endpoint. Written before parsing,
updated before the response is sent.

**This is the only debugging surface.** A Python MCP server fails with a
traceback; this one fails as a client that connects and then does nothing.
Without the log you are guessing.

Delivery class `L` (application table, transaction data). Data class `APPL1`,
size category `0`.

| Field | Key | Type | Description |
|---|---|---|---|
| `MANDT` | X | `MANDT` | Client |
| `GUID` | X | `CHAR32` | Request id |
| `CREATED_ON` | | `DATS` | Date |
| `CREATED_AT` | | `TIMS` | Time |
| `UNAME` | | `CHAR12` | Calling SAP user |
| `METHOD` | | `CHAR40` | JSON-RPC method, e.g. `tools/call` |
| `TOOL_NAME` | | `CHAR40` | Tool name, for `tools/call` only |
| `HAS_ID` | | `CHAR1` | `X` = request, blank = notification |
| `REQ_BODY` | | `STRING` | Raw request, capped at 20,000 chars |
| `REQ_BYTES` | | `INT4` | Full request length before capping |
| `RESP_BODY` | | `STRING` | Raw response, capped |
| `RESP_BYTES` | | `INT4` | Full response length |
| `HTTP_CODE` | | `CHAR3` | Status returned |
| `DURATION` | | `INT4` | Milliseconds |
| `STATUS` | | `CHAR1` | `O` open, `S` success, `E` error |
| `ERR_TEXT` | | `CHAR255` | Exception text where one was caught |

**Secondary index Z01:** `CREATED_ON`, `UNAME` — the report filters on both.

### Reading it

The three questions it answers, in the order you will need them:

**Client hangs on connect.** Look for a row where `HAS_ID` is blank and
`RESP_BODY` is not empty. That is the notification bug — a notification was
answered with a body and the client is waiting for a handshake that already
finished.

**Client connects but no tools appear.** Find the `tools/list` row and read
`RESP_BODY`. Check the key is `inputSchema`, camelCase — MCP and the Anthropic
Messages API disagree on that one name.

**A tool returns nothing useful.** Find the `tools/call` row, read the request
body for the exact arguments and the response for what came back. This is how
you see that the model asked for `FORMGET_DATA` when the routine is called
`GET_DATA`.

### Privacy and retention

`REQ_BODY` contains whatever was asked — object names, and in a `tools/call`
the arguments. That is your colleagues' questions sitting in a table.

Switch body capture off once a deployment is stable (see `ZABAPMCP_CFG` below),
and delete old rows. A two-line report in `SM36`:

```abap
DELETE FROM zabapmcp_log WHERE created_on < lv_cutoff.
```

Thirty days is generous for a debugging log. Keep `STATUS = 'E'` rows longer if
you want a failure record.

---

## ZABAPMCP_CFG — configuration

Key-value settings, so behaviour can change without a transport.

Delivery class `C` (customising), data class `APPL2`, size category `0`.
Generate a table maintenance dialogue so it can be edited in SM30.

| Field | Key | Type | Description |
|---|---|---|---|
| `MANDT` | X | `MANDT` | Client |
| `CFG_KEY` | X | `CHAR30` | Setting name |
| `CFG_VALUE` | | `CHAR60` | Value |
| `DESCRIPTION` | | `CHAR120` | What it does |

### Recognised keys

| Key | Values | Default | Effect |
|---|---|---|---|
| `CAPTURE_BODIES` | `ON` / `OFF` | `ON` | Store raw request and response text in the log |
| `TOOLS_DISABLED` | comma-separated tool names | empty | Tools switched off in this system |

### TOOLS_DISABLED

Some sites are comfortable exposing DDIC metadata and where-used but not full
source. Others want to switch a tool off after an incident without waiting for
a transport. Set the value to a comma-separated list:

```
sap_get_source,sap_search_objects
```

A disabled tool disappears from `tools/list` **and** refuses to run if called
directly — a client holding a cached catalogue would otherwise still reach it.

Tool names are case-insensitive here. Leave the row absent, or the value empty,
to expose everything.

An absent row means the default. `CAPTURE_BODIES` reads as `ON` unless a row
explicitly says `OFF`, so a fresh install is debuggable and you switch it off
deliberately.

Keep this table small. Configuration that belongs in code should stay in code —
this exists for the handful of things you genuinely want to change on a running
system without a transport.

---

## Creating them

Nothing here needs a data element beyond the standard ones. In SE11:

1. Create the table, delivery class as noted above
2. Add the fields with the built-in types shown
3. Technical settings: data class and size category as noted
4. For `ZABAPMCP_CFG`, Utilities → Table Maintenance Generator, one-step,
   authorisation group `&NC&`
5. For `ZABAPMCP_LOG`, add secondary index Z01 on `CREATED_ON`, `UNAME`

`STRING` fields become LOBs on most databases, stored outside the row. That is
fine — but never write `SELECT *` on `ZABAPMCP_LOG` in a list report, or you
drag every captured body across the wire. Select the fields you need.
