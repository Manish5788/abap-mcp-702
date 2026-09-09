# Security

What this server does and does not protect, stated precisely — because the
distinction matters and a reviewer will find it if you blur it.

---

## The three properties that matter

**Read-only by construction.** Every tool is a `SELECT` or a `READ REPORT`.
There is no write path in the codebase. This is not a policy that could be
relaxed; it is an absence of code.

**Runs as the calling user.** The ICF node authenticates, and the tools then
execute under that person's own SAP user. Anything readable through this server
was already readable by that person in SE38.

**Custom namespace only.** `CHECK_CUSTOM` gates every tool before its body
runs. Names must start with `Z` or `Y`. Enforced in ABAP, not requested in a
prompt — a prompt rule is advice, this is a gate.

---

## What the authorisation object does, and does not, do

`ZABAPMCP` controls **feature access** — whether a person may use this server
at all. It does **not** control data exposure, because the tools already run
under that person's own authorisations.

Do not describe it as a data control. A reviewer will spot the difference, and
overclaiming on this point costs credibility on the parts that are genuinely
strong.

### Creating it

Optional. If the object does not exist, `CHECK_AUTH` treats that as "not
configured" and allows the call, so a fresh install works without SU21 work.
Create the object to switch gating on.

SU21, object class as you prefer:

```
ZABAPMCP   MCP server access
  ACTVT    Activity   03 (display)
```

Then grant `ZABAPMCP` with `ACTVT = 03` in the roles that should reach the
server. Anyone without it gets a clean 403.

If you want per-tool gating, add a second field and extend `CHECK_AUTH` to take
the tool name — the hook is there, deliberately unused, because most
deployments will not need it.

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
anyone with broad `S_TABU_DIS`.

---

## Transport security

Use HTTPS on the ICF node. Basic auth over plain HTTP puts SAP credentials on
the wire in base64, which is encoding, not encryption.

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
