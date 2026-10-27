# abap-mcp-702

## ABAP MCP Server for SAP ECC 6.0

Connect AI agents to the real ABAP repository in SAP ECC 6.0 / NetWeaver 7.02 — with a native ABAP MCP server built for legacy SAP landscapes.

When modern tooling does not reach your ECC system, abap-mcp-702 gives MCP-compatible clients such as Claude Code access to current system facts instead of pasted snippets.

No SAP BTP subscription, Python middleware or ADT required.

**Status:** working in a production-adjacent development system. Tested on ECC 6.0 EHP5 / NetWeaver 7.02. Evaluate in a development system first.

## What it gives an agent

21 read-only tools over the live system:

| Area | Tools | What they provide |
|---|---|---|
| Code | `sap_get_source`, `sap_search_objects`, `sap_where_used`, `sap_search_source` | Source of custom programs, includes and classes (large objects as a structural skeleton plus the routines with the most logic), name search, where-used, text search in source headers |
| Dictionary | `sap_get_ddic`, `sap_find_field`, `sap_message_info`, `sap_auth_object_info` | Field lists of custom and standard tables, which tables hold a field, message texts, authorization objects |
| Configuration | `sap_tcode_info`, `sap_find_config`, `sap_read_config` | Transactions, IMG activities, rows of configuration tables under the caller's own table authorization |
| Transports | `sap_transport_search`, `sap_object_transports`, `sap_open_requests` | Requests by description, history of one object, open requests with their changed parts |
| Diagnostics | `sap_get_dumps`, `sap_whoami` | ST22 short dumps of a day with the deepest custom frame; who and where the session is |
| BW extraction | `sap_bw_datasources`, `sap_bw_datasource_info`, `sap_bw_table_datasources` | DataSources, their source tables, delta method, connected BW systems and custom exit code |
| Exact source | `sap_list_package`, `sap_get_raw_source` | Byte-exact source and hashes of a package, for local workspaces |

Ask questions such as:

- What does this custom program do, and where is it used?
- Which configuration decides this behaviour, and what is it set to here?
- Which objects belong to this project, and how far has each got in the landscape?
- Why did this program dump yesterday?
- Which DataSource extracts this table, and what does the custom exit change?

Start code comprehension and impact analysis with information from your own system.

## Why it matters

Legacy ECC landscapes contain years of custom code, business logic and dependencies. Documentation may be incomplete, and the original developers may no longer be available.

abap-mcp-702 brings that repository context into AI-assisted workflows, helping teams understand existing code and investigate the impact of proposed changes before development begins.

## Security posture

- **Read-only MCP endpoint:** no tool writes, activates, debugs or transports.
- **Runs as the calling SAP user:** existing user authorisations remain relevant.
- **Custom namespace scope for code:** source and where-used are restricted to custom namespaces; SAP standard objects are visible as metadata only, and table rows only from configuration tables.
- **Central access control:** one class decides who may come in and which tool groups each user may call; refusals are logged.
- **Development-first evaluation:** review your own access controls and security requirements before deployment.

The repository also contains **abapsync**, an optional add-on for pushing code from a local workspace to development systems. It writes, so it is kept separate: its own ICF service, off until you activate it, refused outside development clients. Its classes are installed with the server because the exact-source tools reuse their read helpers. See [abapsync/README.md](abapsync/README.md).

Read-only does not mean risk-free: repository source and metadata may be sensitive. Review what an AI client may receive and your organisation's data-handling requirements.

## Compatibility and limitations

- Targets SAP NetWeaver 7.02 or higher; validation across other releases is still limited.
- Requires ajson and abapGit's developer version in the system.
- Supports programs, includes, classes, function groups, DDIC, configuration, transport, short-dump and BW extraction metadata.
- Activated source only; inactive changes are not visible.
- Smart Forms, screen flow logic, generated table-maintenance code and enhancement implementations are not covered.
- Where-used results depend on the system's cross-reference freshness; recent changes may not appear immediately.
- Exposes MCP tools, not resources, prompts or sampling.
- No write, activation, debugging or transport operations are planned for the MCP endpoint.

## Getting it into your system

Every SAP landscape has different release levels, access requirements and custom-code boundaries. The right rollout starts with those details.

**Interested in connecting AI to your ECC system?** Tell me your ECC release, NetWeaver version and what your team wants to investigate. I can walk you through compatibility, access scope and rollout considerations.

[Contact Manish Kumar Rajak](https://maniabap.dev/#contact)

[Read the project overview](https://maniabap.dev/blog/abap-mcp-server-ecc-702)

## Contributing

Issues and pull requests are welcome, particularly for testing on additional SAP releases and extending read-only capabilities.

Please keep the MCP endpoint read-only. Contributions that add a writing tool to it will not be merged; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

MIT. See [LICENSE](LICENSE).

## Acknowledgements

Thanks to the open-source maintainers whose work supports this project. Third-party projects are not affiliated with abap-mcp-702; their licences and credits remain applicable.
