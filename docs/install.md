# Installing

Tested on SAP ECC 6.0 EHP5, SAP_BASIS 7.02. Install in a development system
first.

---

## 1. Prerequisites

| Dependency | Why | Notes |
|---|---|---|
| [ajson](https://github.com/sbcgua/ajson) | All JSON parsing and building | Pure ABAP, so the SP level of 7.02 does not matter |
| [abapGit](https://github.com/abapGit/abapGit), **developer version** | `ZCL_ABAPMCP_SYNC` and the abapsync classes reuse abapGit's global classes (`ZCL_ABAPGIT_HASH`, `ZCL_ABAPGIT_OO_CLASS`, `ZCL_ABAPGIT_OBJECT_*`, `ZCL_ABAPGIT_OBJECTS_ACTIVATION`, `ZCL_ABAPGIT_CTS_API`) | The standalone report is not enough - it has only local classes. Tested with abapGit 1.134.0; abapsync calls abapGit internals, so a much newer or older release may not activate. |

## 2. Dictionary

Create the objects in `ddic/` with SE11. The files are the dictionary
definitions in JSON (DD02V/DD03P/DD09L for tables, DD04V for data elements,
DD01V/DD07V for domains), the format the abapsync CLI pushes. Order: domains,
data elements, tables. Details and settings: [ddic.md](ddic.md).

## 3. Authorization fields and objects

SU20 - authorization fields:

| Field | Data element |
|---|---|
| `ZUSER` | `XUBNAME` |
| `Z_AICHAN` | `ZAI_CHAN` |
| `Z_AITGRP` | `ZAI_TGRP` |
| `Z_AIOWN` | `ZAI_OWN` |
| `Z_AIADM` | `ZAI_ADM` |

SU21 - objects (one object class of your choice):

| Object | Fields | Checked for |
|---|---|---|
| `ZMCP_USE` | `ZUSER`, `ACTVT` | Simple gate while `AUTH_MODE` is `LEGACY` or `DUAL`; abapsync push gate |
| `Z_AI_CHAN` | `ZUSER`, `Z_AICHAN`, `ACTVT` | Way in. The MCP node checks `MCP`; `SYNC` and `JOB` are defined for callers you add |
| `Z_AI_TOOL` | `ZUSER`, `Z_AITGRP`, `ACTVT` | Tool group of the called tool |
| `Z_AI_SCOPE` | `ZUSER`, `Z_AIOWN`, `DEVCLASS`, `ACTVT` | Other users' requests and dumps (`OWN`/`ANY`); which packages' code may be read |
| `Z_AI_ADM` | `ZUSER`, `Z_AIADM`, `ACTVT` | Tool switches and log viewers (`TOOLSW`, `LOG`) |
| `Z_AI_SYNC` | `ZUSER`, `DEVCLASS`, `ACTVT` | Optional: `ZCL_AI_AUTH=>CHECK_SYNC` for a per-package push gate; the abapsync writer does not call it yet |

`ZUSER` is always checked against the logged-on user; grant `$USER`-style
values or `*` in the role as your security team prefers. `ACTVT` is always 03.

`ZMCP_USE` is only a name: to reuse an object you already have, change
`C_LEGACY_OBJECT` in `ZCL_AI_AUTH` and `C_AUTH_OBJECT` in `ZCL_ABAPSYNC_WRITE`.
Note that `AUTHORITY-CHECK` on an object that does not exist fails, so in
`LEGACY` mode nobody gets in until the object exists and is granted.

## 4. Classes and programs

Activate in this order (each step depends on the one before):

1. `abapsync/src/` - `ZCL_ABAPSYNC_CHECK`, `ZCL_ABAPSYNC_POST`,
   `ZCL_ABAPSYNC_DDIC`, `ZCL_ABAPSYNC_REPO`, `ZCL_ABAPSYNC_WRITE`
   (see [abapsync/README.md](../abapsync/README.md) - installing the classes
   does not switch writing on)
2. `src/` - `ZCL_AI_AUTH`, `ZCL_ABAPMCP_LOG`, `ZCL_ABAPMCP_STRUCTURE`, the
   plug-ins `ZCL_ABAPMCP_CUST`, `_CTS`, `_DIAG`, `_BW`, `_WHOAMI`, `_SYNC`,
   then `ZCL_ABAPMCP_TOOLS` and `ZCL_ABAPMCP_SERVER`
3. Programs `ZABAPMCP_LOG_VIEW`, `ZABAPMCP_CUSTLOG_VIEW`, `ZAI_TOOL_GRP_SEED`

The tool classes and the abapsync classes reference each other, so the first
activation may report missing classes: activate the whole set together
(SE80 worklist) rather than one by one.

## 5. Tool groups

Run `ZAI_TOOL_GRP_SEED` once. It fills `ZAI_TOOL_GRP` (tool -> group). A tool
without an active row is refused, so a new tool needs a row before anyone can
call it - deliberately.

## 6. ICF node

SICF, under `/default_host/sap/bc/`:

- Create service `mcp`, handler list `ZCL_ABAPMCP_SERVER`
- Logon data: standard logon, no service user - the tools must run as the
  person asking
- Activate the service

HTTPS is required by default; for a first test on plain HTTP set
`ZABAPMCP_CFG` key `REQUIRE_SSL` = `OFF`, and switch it back.

## 7. Configuration

`ZABAPMCP_CFG` (SM30), all optional:

| Key | Values | Default |
|---|---|---|
| `AUTH_MODE` | `LEGACY`, `DUAL`, `NEW` | `LEGACY` (no row) |
| `TOOLS_DISABLED` | comma-separated tool names | none |
| `CAPTURE_BODIES` | `ON` / `OFF` | `ON` |
| `REQUIRE_SSL` | `ON` / `OFF` | `ON` |
| `CUST_LOG` | `ON` / `OFF` | `ON` - audit row in `ZMCP_CUST_LOG` per configuration lookup |
| `PROTOCOL_VERSIONS` | comma-separated MCP versions, oldest first | built in |
| `SPRO_TREE` | IMG structure id for `sap_find_config` | SAP reference IMG |
| `ABAPSYNC_WRITE` | `ON` / `OFF` | `ON` - kill switch for abapsync push |

## 8. Smoke test

From a logged-on browser or `curl` (see [mcp-client.md](mcp-client.md)):
`initialize`, then `tools/list` - expect 21 tools, minus any you disabled or
whose group the user lacks. Then `tools/call` `sap_whoami`: it reports system,
client role, user type and probes of the caller's own authorizations.
