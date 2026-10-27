# Security

What this server does and does not protect, stated precisely — because the
distinction matters and a reviewer will find it if you blur it.

---

## The three properties that matter

**The MCP endpoint is read-only.** Every tool behind `/sap/bc/mcp` is a
`SELECT`, a `READ REPORT` or a standard read API. No tool writes, activates,
locks or transports.

The repository also contains **abapsync**, an optional add-on that *does*
write code to development systems. It is a separate ICF service, off until you
create and activate that node, and it refuses non-development clients. Its
classes have to be installed because the MCP sync tools reuse their read
helpers - see [abapsync/README.md](../abapsync/README.md). If your approval
process needs "no write code in the system at all", this edition does not meet
it.

**Runs as the calling user.** The ICF node authenticates, and the tools then
execute under that person's own SAP user. SAP's own checks stay in the tools:
`S_TABU_DIS`/`S_TABU_NAM` for configuration rows, `S_TRANSPRT` for transport
data, `S_DEVELOP` for source.

**Custom namespace for code.** `CHECK_CUSTOM` gates every source and
where-used tool before its body runs. Names must start with `Z` or `Y`.
Enforced in ABAP, not requested in a prompt - a prompt rule is advice, this is
a gate. Metadata of SAP standard objects (DDIC field lists, transactions, IMG,
messages, authorization objects, BW DataSources) is readable by design; table
**rows** only from configuration tables (delivery class C, G, E) and never from
a hard blocklist (HR, payroll, user master, bank and card data).

---

## Who may use which tool - ZCL_AI_AUTH

One class decides; no tool writes its own check for these objects. Objects and
fields: [install.md](install.md#3-authorization-fields-and-objects).

| Object | Decides |
|---|---|
| `Z_AI_CHAN` | May the user come in through this channel (`MCP`)? |
| `Z_AI_TOOL` | May the user call a tool of this group? Tool -> group is table `ZAI_TOOL_GRP`; a tool without an active row is refused, and `tools/list` shows only the caller's tools |
| `Z_AI_SCOPE` | Other users' open requests and dumps (`ANY`) or only one's own (`OWN`); which packages' code may be read |
| `Z_AI_ADM` | Tool switches and the log viewers |
| `ZMCP_USE` | The simple gate: one object, `ACTVT 03` |

`ZABAPMCP_CFG` key `AUTH_MODE` chooses the rule:

| Mode | Effect |
|---|---|
| `LEGACY` (default) | `ZMCP_USE` alone decides |
| `DUAL` | `ZMCP_USE` decides; where the `Z_AI_*` objects would refuse, a row with status `W` goes to `ZABAPMCP_LOG` - run this while building roles to see what is missing |
| `NEW` | The `Z_AI_*` objects decide; refusals are logged with status `R` |

`AUTHORITY-CHECK` on an object that does not exist fails, so nothing works
until the object of the active mode is created and granted. That is
deliberate: a fresh install is closed, not open.

These objects control **feature access**. They do not widen data exposure -
the tools still run under the caller's own SAP authorizations. Do not describe
them as a data control.

---

## Narrowing what is exposed

Every tool is read-only, but not every site wants every tool. DDIC metadata and
where-used are uncontroversial; full source is a different conversation in some
organisations.

`ZABAPMCP_CFG` key `TOOLS_DISABLED` takes a comma-separated list of tool names.
Those tools disappear from `tools/list` and refuse to run if called directly —
both, because a client holding a cached catalogue would otherwise still reach
a tool that had been switched off.

This is configuration, not code, so it can be changed on a running system
without a transport.

## The log holds what people asked

`ZABAPMCP_LOG.REQ_BODY` contains the raw request, which for a `tools/call`
includes the arguments — object names, patterns, whatever was being
investigated. That is your colleagues' work sitting in a table.

Two things follow:

**Switch capture off once stable.** Set `CAPTURE_BODIES` to `OFF` in
`ZABAPMCP_CFG`. Metadata — who, when, which tool, how long, success or failure
— is still recorded, which is enough for operations. Bodies are a debugging
aid, not an audit requirement.

**Retain briefly.** Thirty days is generous for a debugging log. A scheduled
report doing `DELETE FROM zabapmcp_log WHERE created_on < lv_cutoff.` is the
whole implementation.

Consider a dedicated authorisation group on the table so it is not readable by
anyone with broad `S_TABU_DIS`. The same applies to `ZMCP_CUST_LOG`, which
records every configuration lookup with its arguments (`CUST_LOG` = `OFF`
switches it off). The viewers `ZABAPMCP_LOG_VIEW` and `ZABAPMCP_CUSTLOG_VIEW`
additionally need `Z_AI_ADM` = `LOG`.

---

## Transport security

Use HTTPS on the ICF node. Basic auth over plain HTTP puts SAP credentials on
the wire in base64, which is encoding, not encryption. The server refuses a
plain-HTTP call with 403 unless `ZABAPMCP_CFG` key `REQUIRE_SSL` is `OFF` -
keep that override for a first test on a closed network only.

For a shared deployment, configure the node for whatever your landscape already
uses — SSO, X.509, SAML — rather than distributing passwords. The server does
not care how authentication happened; it only uses `sy-uname` afterwards.

---

## Where to deploy

DEV first. There is no technical block on other systems, and the read-only
property means the risk is bounded, but start where a mistake is cheap.

Before going further, decide two things deliberately:

- Whether an LLM vendor should see your custom source at all. The server does
  not send anything anywhere — a client does — but that client is usually
  routing through a model vendor, and that is a data question your organisation
  may have a view on.
- Whether `CAPTURE_BODIES` should be on outside DEV.

---

## What this does not defend against

Stated plainly, because pretending otherwise is worse than the gap:

- **A user reading their own permitted data through a different interface.**
  That is the design, not a weakness.
- **Prompt injection in retrieved source.** If a Z program contains text
  attempting to redirect a model, the model reads it. The blast radius is
  bounded — the tool schema is fixed and dispatched by name, so no text in a
  source file can grant access to anything the caller lacks — but the model's
  *answer* could be influenced.
- **Denial of service.** A caller can issue expensive `sap_where_used` queries
  in a loop. `c_max_rows` caps each one, but nothing rate-limits the sequence.
  On an internal DEV system with named users this has not been worth solving.
