# abapsync - optional write add-on

**This part writes code.** It is separate from the MCP server on purpose.

abapsync lets a developer keep ABAP source in a local folder, edit it with any
editor or agent, and push it back to a **development** system - without ADT,
which 7.02 does not have. The read side (`sap_list_package`,
`sap_get_raw_source`) is served by the MCP node; the write side is its own ICF
service.

## What is here

| Class | Role |
|---|---|
| `ZCL_ABAPSYNC_WRITE` | ICF handler of the write node: validates every part, records it in the transport, saves inactive, activates in one run |
| `ZCL_ABAPSYNC_CHECK` | Syntax check before activation (a syntax error otherwise raises a popup, which dumps over HTTP) |
| `ZCL_ABAPSYNC_REPO` | New programs, text pools, transactions |
| `ZCL_ABAPSYNC_DDIC` | Tables, data elements, domains (also read by the MCP sync tools) |
| `ZCL_ABAPSYNC_POST` | Post-processing of a push |

Every part is logged in `ZABAPSYNC_LOG`.

## Why the classes are installed even if you never push

`ZCL_ABAPMCP_SYNC` (MCP read tools) reuses `ZCL_ABAPSYNC_DDIC` and
`ZCL_ABAPSYNC_REPO` for exact source and dictionary reads, so these classes
must exist for the MCP server to activate. Installing them does **not** make
anything writable:

- **No ICF node, no write.** Nothing reaches `ZCL_ABAPSYNC_WRITE` until you
  create and activate a separate SICF service (e.g. `/sap/bc/zabapsync`) with
  it as handler. The MCP node `/sap/bc/mcp` has no write tool.
- **Development systems only.** A push is refused when the client does not
  allow changes to repository objects (T000 / SCC4).
- **Kill switch.** `ZABAPMCP_CFG` key `ABAPSYNC_WRITE` = `OFF` refuses every
  push without a transport.
- **Authorizations.** `S_DEVELOP` as SE38/SE24/SE11 would check it, plus the
  push gate (`C_AUTH_OBJECT`, default `ZMCP_USE`). `ZCL_AI_AUTH=>CHECK_SYNC`
  (`Z_AI_SYNC` per package) exists but the writer does not call it yet.
- **Scope.** Only `Z`/`Y` objects; drift against the server version is checked
  by hash before anything is saved.

## Enabling it

1. SICF: create a service for `ZCL_ABAPSYNC_WRITE`, standard logon, HTTPS,
   activate it - in development systems only, never in QA or production
2. Grant `S_DEVELOP` and `ZMCP_USE` (ACTVT 03)
3. Point the abapsync CLI at the host (base URL only) with the read path
   `/sap/bc/mcp` and your write path

The CLI is not part of this repository.
