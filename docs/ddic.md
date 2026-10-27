# DDIC objects

Five tables, plus the domains and data elements they use. None holds business
data. The exact definitions are in [`ddic/`](../ddic) as JSON (DD02V, DD03P,
DD09L for tables; DD04V for data elements; DD01V/DD07V for domains) - create
them in SE11 from those, or push them with the abapsync CLI. Create domains
first, then data elements, then tables.

| Table | Purpose | Written by |
|---|---|---|
| `ZABAPMCP_LOG` | One row per HTTP request to `/sap/bc/mcp`; also authorization refusals (method `AUTH`) | `ZCL_ABAPMCP_LOG`, `ZCL_AI_AUTH` |
| `ZABAPMCP_CFG` | Key-value settings | you (SM30) |
| `ZAI_TOOL_GRP` | Tool -> tool group for `Z_AI_TOOL` | `ZAI_TOOL_GRP_SEED`, SM30 |
| `ZMCP_CUST_LOG` | One row per configuration lookup (`sap_read_config` and friends) | `ZCL_ABAPMCP_CUST` |
| `ZABAPSYNC_LOG` | One row per pushed part | abapsync (only if its node is active) |

---

## ZABAPMCP_LOG - request log

Written before parsing, updated before the response is sent.

**This is the only debugging surface.** A Python MCP server fails with a
traceback; this one fails as a client that connects and then does nothing.
Without the log you are guessing.

| Field | Key | Data element | Description |
|---|---|---|---|
| `MANDT` | X | `MANDT` | Client |
| `GUID` | X | `CHAR32` | Request id |
| `CREATED_ON` | | `ERDAT` | Date |
| `ERZET` | | `ERZET` | Time |
| `ERNAM` | | `ERNAM` | Calling SAP user |
| `METHOD` | | `CHAR40` | JSON-RPC method, e.g. `tools/call`; `AUTH` for a refusal |
| `TOOL_NAME` | | `CHAR40` | Tool name for `tools/call`; what was refused for `AUTH` |
| `HAS_ID` | | `CHAR1` | `X` = request, blank = notification |
| `REQ_BODY` | | `STRING` | Raw request, capped at 20,000 chars |
| `REQ_BYTES` | | `INT4` | Full request length before capping |
| `RESP_BODY` | | `STRING` | Raw response, capped |
| `RESP_BYTES` | | `INT4` | Full response length |
| `HTTP_CODE` | | `CHAR3` | Status returned |
| `DURATION` | | `INT4` | Milliseconds |
| `STATUS` | | `CHAR1` | `O` open, `S` success, `E` error; `R` refused, `W` would be refused (`AUTH_MODE DUAL`) |
| `ERR_TEXT` | | `CHAR255` | Exception or refusal text |

A secondary index on `CREATED_ON`, `ERNAM` helps the viewer.

### Reading it

`ZABAPMCP_LOG_VIEW` classifies rows. The three questions, in the order you will
need them:

**Client hangs on connect.** Look for a row where `HAS_ID` is blank and
`RESP_BODY` is not empty. That is the notification bug - a notification was
answered with a body and the client is waiting for a handshake that already
finished.

**Client connects but no tools appear.** Find the `tools/list` row and read
`RESP_BODY`. Check the key is `inputSchema`, camelCase. If the list is short,
look for `AUTH` rows: `tools/list` shows only the tools of the caller's groups.

**A tool returns nothing useful.** Find the `tools/call` row, read the request
body for the exact arguments and the response for what came back.

### Privacy and retention

`REQ_BODY` contains whatever was asked - object names, and in a `tools/call`
the arguments. Switch body capture off once a deployment is stable
(`CAPTURE_BODIES` = `OFF`) and delete old rows:

```abap
DELETE FROM zabapmcp_log WHERE created_on < lv_cutoff.
```

`STRING` fields become LOBs on most databases. Never `SELECT *` on this table
in a list report - select the fields you need.

---

## ZABAPMCP_CFG - configuration

Key-value settings, so behaviour can change without a transport. Generate a
table maintenance dialogue (one step) so it can be edited in SM30.

| Field | Key | Data element | Description |
|---|---|---|---|
| `MANDT` | X | `MANDT` | Client |
| `CFG_KEY` | X | `CHAR30` | Setting name |
| `CFG_VALUE` | | `ZCHAR60` | Value |
| `DESCRIPTION` | | `CHAR120` | What it does |

Recognised keys: [install.md](install.md#7-configuration). An absent row means
the default.

### TOOLS_DISABLED

A comma-separated list of tool names, e.g. `sap_get_source,sap_read_config`.
A disabled tool disappears from `tools/list` **and** refuses to run if called
directly - a client holding a cached catalogue would otherwise still reach it.

---

## ZAI_TOOL_GRP - tool groups

| Field | Key | Data element | Description |
|---|---|---|---|
| `MANDT` | X | `MANDT` | Client |
| `TOOL_NAME` | X | `ZAI_TOOL` | MCP tool name (lower case) |
| `TOOL_GROUP` | | `ZAI_TGRP` | `CONFIG`, `DDIC`, `SEARCH`, `CODE`, `TRANSP`, `REVIEW`, `DIAG`, `BW` |
| `ACTIVE` | | `XFELD` | Only active rows count |

Customizing table. `ZAI_TOOL_GRP_SEED` fills the rows for the shipped tools.

---

## ZMCP_CUST_LOG - configuration lookup audit

| Field | Key | Data element | Description |
|---|---|---|---|
| `MANDT` | X | `MANDT` | Client |
| `LOG_ID` | X | `GUID_32` | Row id |
| `TSTAMP` | | `TIMESTAMPL` | When |
| `UNAME` | | `SYUNAME` | Who |
| `TOOL` | | `ZMCP_CL_TOOL` | Tool |
| `STATUS` | | `ZMCP_CL_STATUS` | Outcome |
| `TARGET` | | `ZMCP_CL_TARGET` | Table, transaction or IMG node |
| `ARGS` | | `ZMCP_CL_ARGS` | Arguments as sent |
| `MESSAGE` | | `ZMCP_CL_MESSAGE` | Error or refusal text |
| `ROWS_RET` | | `ZMCP_CL_ROWS` | Rows returned |
| `ROWS_TOTAL` | | `ZMCP_CL_TOTAL` | Rows matching |
| `DURATION` | | `ZMCP_CL_DURATION` | Milliseconds |

Read it with `ZABAPMCP_CUSTLOG_VIEW`. `CUST_LOG` = `OFF` stops writing.

---

## ZABAPSYNC_LOG - abapsync push log

| Field | Key | Data element | Description |
|---|---|---|---|
| `MANDT` | X | `MANDT` | Client |
| `LOG_ID` | X | `GUID_32` | Row id |
| `TSTAMP` | | `TIMESTAMPL` | When |
| `UNAME` | | `SYUNAME` | Who |
| `ACTION` | | `CHAR10` | What was asked |
| `OBJECT` | | `TROBJTYPE` | Object type |
| `OBJ_NAME` | | `SOBJ_NAME` | Object name |
| `INCLUDE` | | `PROGNAME` | Include written |
| `TRKORR` | | `TRKORR` | Transport request |
| `STATUS` | | `CHAR10` | Outcome |
| `STATE` | | `CHAR1` | Active / inactive |
| `NEW_HASH` | | `CHAR40` | Hash of the saved source |
| `MESSAGE` | | `CHAR255` | Error or note |

Stays empty unless the abapsync write node is activated.
