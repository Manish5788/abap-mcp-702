# abap-mcp-702

An MCP server that runs **inside** SAP ECC 6.0, on NetWeaver 7.02.

SAP's ABAP MCP server requires NetWeaver 7.31 SP04 or higher, because it is
built on the ABAP Language Server that ADT needs. Every community MCP server
for ABAP is likewise ADT-based. If you are on ECC 6.0 with a 7.0x kernel, none
of them reach your system.

This one does. It speaks the Model Context Protocol natively — JSON-RPC 2.0
over HTTP, implemented in ABAP — so an MCP client connects straight to an ICF
node. No Python adapter, no add-on, no BTP subscription, no ADT.

**Status:** working in a production-adjacent DEV system. Read-only by
construction. See [Limitations](#limitations) before you rely on it.

---

## What it gives an agent

Four read-only tools over the live repository:

| Tool | Answers |
|---|---|
| `sap_get_source` | The real source of a custom program, include or class |
| `sap_get_ddic` | Field list of a table or structure — names, types, lengths, keys |
| `sap_search_objects` | Repository search by name pattern |
| `sap_where_used` | Where-used across `WBCROSSGT` and `CROSS` — tables, function modules, classes, methods, FORMs |

Point Claude Code, or any MCP client, at it and ask questions about your own
ABAP against the live system rather than against a training snapshot.

```
> what does ZRWM_RFQI_POST do?
> where is ZAI_API_LOG used?
> which programs call BAPI_GOODSMVT_CREATE?
```

---

## Why you might want this

Mainstream maintenance for ECC 6.0 runs to 2027, extended to 2030. A great many
organisations will still be on it for years — because a migration is expensive,
or the business case has not closed, or the timing is wrong. Those systems get
none of the AI tooling being built for S/4 and ABAP Cloud.

The custom code in a twenty-year-old ECC system is exactly where an agent helps
most: nobody remembers what half of it does, the people who wrote it have moved
on, and the specs are out of date. That is a comprehension problem, and it is
the one thing a model is genuinely good at.

---

## Design

Three properties, in order of importance.

**Read-only by construction.** Every tool is a `SELECT` or a `READ REPORT`.
There is no write path in the code — not a policy, an absence. That is what
makes it deployable without a long approval cycle.

**Runs as the calling user.** No shared service account. The agent sees exactly
what that developer could already open in SE38, and their own authorizations
apply.

**Custom namespace only.** Names must start with `Z` or `Y`, enforced in ABAP
before any tool runs. SAP standard objects are refused. This is a guard in
code, not an instruction in a prompt.

Everything else follows from those three.

---

## Install

**Requirements**

- SAP NetWeaver 7.02 or higher (tested on ECC 6.0 EHP5, DB6/AIX)
- [abapGit](https://abapgit.org)
- [ajson](https://github.com/sbcgua/ajson) — the only dependency

**Steps**

1. Install ajson via abapGit if you do not already have it.
2. Clone this repository into a new package, e.g. `ZMCP`.
3. Create the two tables from [`docs/ddic.md`](docs/ddic.md) — `ZABAPMCP_LOG`
   and `ZABAPMCP_CFG`. Neither holds business data.
4. Activate all objects.
5. Create an ICF node in SICF under `/sap/bc/`, name it `mcp`, and set the
   handler class to `ZCL_ABAPMCP_SERVER`. Activate the node.
6. Confirm the handshake answers:

```bash
curl -k -u YOURUSER -X POST \
  'https://<host>:<port>/sap/bc/mcp?sap-client=100' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

You should get `protocolVersion`, `capabilities` and `serverInfo` back. If that
works, everything else is dispatch.

Opening the same URL in a browser returns a plain-text confirmation that the
node is reachable, the handler is bound and your user authenticated — useful
before wrestling with curl.

**Connecting a client** — see [`docs/mcp-client.md`](docs/mcp-client.md) for
Claude Desktop, Claude Code and troubleshooting.

---

## When something does not work

There is no console and no traceback here. The characteristic failure is a
client that connects and then silently does nothing.

`ZABAPMCP_LOG_VIEW` is the answer. Run it with **problems only** ticked. It
classifies every request and flags four patterns:

| Flag | Meaning |
|---|---|
| `NOTIFY-ANSWERED` | A notification received a response body. This is why a client hangs on connect — it is waiting for a handshake that already finished. The most common cause by a wide margin. |
| `RPC-ERROR` | The response carried a JSON-RPC error |
| `CAUGHT` | An ABAP exception was caught during dispatch |
| `OPEN` | The row was never closed, so the work process died mid-request. Check ST22. |

Paste a GUID into the second selection block to see the full request and
response as sent. That is how you find out the model asked for a routine name
that does not exist, or that `inputSchema` went out as `input_schema`.

Request and response bodies are captured by default. Switch that off once a
deployment is stable — set `CAPTURE_BODIES` to `OFF` in `ZABAPMCP_CFG`.

---

## Objects

| Object | Type | Role |
|---|---|---|
| `ZCL_ABAPMCP_SERVER` | CLAS | MCP protocol — JSON-RPC dispatch, handshake, tool calls |
| `ZCL_ABAPMCP_TOOLS` | CLAS | The four tools, namespace guard |
| `ZCL_ABAPMCP_STRUCTURE` | CLAS | Static analysis and source compression |
| `ZCL_ABAPMCP_LOG` | CLAS | Request logging |
| `ZABAPMCP_LOG` | TABL | One row per request — raw JSON in and out |
| `ZABAPMCP_CFG` | TABL | Key-value settings |
| `ZABAPMCP_LOG_VIEW` | PROG | Log viewer, with a problems-only filter |

`ZCL_ABAPMCP_SERVER` knows about MCP and nothing about the ABAP repository.
`ZCL_ABAPMCP_TOOLS` knows about the repository and nothing about MCP. That
separation means the tools class can also be called directly from an in-system
application without dragging the protocol along.

---

## Source paging

A 2,800-line program does not fit in a model's context, and sending its first
300 lines produces a confident answer about the declarations.

`sap_get_source` therefore returns a **structural skeleton covering the whole
object** — tables read and written, function modules and BAPIs called, every
routine listed by name with a complexity score — plus the source of the
routines carrying the most logic. The agent then requests individual routines
by name.

Roughly 3–5k tokens for an object that would otherwise be 40k, and the coverage
is complete rather than truncated.

---

## Limitations

Stated plainly, because you will hit these.

- **Programs, includes, classes and DDIC only.** No Smart Forms, no screen flow
  logic, no table maintenance generated code, no enhancement implementations.
- **Activated source only.** Uncommitted or inactive changes are invisible.
- **No write, no activation, no debugging, no transport operations.** Those are
  out of scope by design, not on a roadmap.
- **`SYNTAX-CHECK` semantics differ for class pools versus reports on 7.02** —
  relevant if you extend this.
- **The cross-reference index can lag.** A very recently created object may not
  appear in `sap_where_used` yet. SE11's own where-used has the same blind spot.
- **Statement parsing is line-based.** Statements wrapped across lines are
  rejoined before analysis, but colon-chained statements are treated as one.
- **Tools only.** No resources, no prompts, no sampling. Those are not
  implemented and are not advertised in the capabilities, so a well-behaved
  client will not ask for them.

---

## Security

Three properties: read-only by construction, runs as the calling user, custom
namespace only. An optional `ZABAPMCP` authorisation object gates access —
if it does not exist the check is skipped, so a fresh install works without
SU21 work.

The tools run under the caller's own SAP user, so that object controls
**feature access**, not data exposure. Anything readable here was already
readable in SE38 by that person. Do not present it as a data control; a
reviewer will spot the difference.

Full detail, including what this does *not* defend against, in
[`docs/security.md`](docs/security.md).

---

## Contributing

Issues and pull requests welcome, particularly:

- Testing on other 7.0x and 7.3x releases — the release matrix is thin
- Additional read-only tools
- `SNAP` field verification across releases, for ST22 support

Please keep the read-only property intact. A pull request that adds a write
path will not be merged; that is the design, not an oversight.

---

## Licence

MIT. See [LICENSE](LICENSE).

## Acknowledgements

Built on [ajson](https://github.com/sbcgua/ajson) by Alexander Tsybulsky, and
distributed with [abapGit](https://abapgit.org). Neither project is affiliated
with this one.
