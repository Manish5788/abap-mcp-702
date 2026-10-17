# abap-mcp-702

## ABAP MCP Server for SAP ECC 6.0

Connect AI agents to the real ABAP repository in SAP ECC 6.0 / NetWeaver 7.02 — with a native ABAP MCP server built for legacy SAP landscapes.

When modern tooling does not reach your ECC system, abap-mcp-702 gives MCP-compatible clients such as Claude Code access to current system facts instead of pasted snippets.

No SAP BTP subscription, Python middleware or ADT required.

**Status:** working in a production-adjacent development system. Tested on ECC 6.0 EHP5 / NetWeaver 7.02. Evaluate in a development system first.

## What it gives an agent

Four read-only tools over the live repository:

| Tool | What it provides |
|---|---|
| `sap_get_source` | Current source information for a custom program, include or class |
| `sap_get_ddic` | Field lists for tables or structures, including names, types, lengths and keys |
| `sap_search_objects` | Repository search by name pattern |
| `sap_where_used` | Where-used information for tables, function modules, classes, methods and FORM routines |

Ask questions such as:

- What does this custom program do?
- Which fields exist in this Z table?
- Where is this custom function module used?

Start code comprehension and impact analysis with information from your own system.

## Why it matters

Legacy ECC landscapes contain years of custom code, business logic and dependencies. Documentation may be incomplete, and the original developers may no longer be available.

abap-mcp-702 brings that repository context into AI-assisted workflows, helping teams understand existing code and investigate the impact of proposed changes before development begins.

## Security posture

- **Read-only by construction:** no write, activation, debugging or transport operations.
- **Runs as the calling SAP user:** existing user authorisations remain relevant.
- **Custom namespace scope:** object access is restricted to custom namespaces.
- **Development-first evaluation:** review your own access controls and security requirements before deployment.

Read-only does not mean risk-free: repository source and metadata may be sensitive. Review what an AI client may receive and your organisation's data-handling requirements.

## Compatibility and limitations

- Targets SAP NetWeaver 7.02 or higher; validation across other releases is still limited.
- Supports programs, includes, classes and DDIC information.
- Activated source only; inactive changes are not visible.
- Smart Forms, screen flow logic, generated table-maintenance code and enhancement implementations are not covered.
- Where-used results depend on the system's cross-reference freshness; recent changes may not appear immediately.
- Exposes MCP tools, not resources, prompts or sampling.
- No write, activation, debugging or transport operations are planned.

## Getting it into your system

Every SAP landscape has different release levels, access requirements and custom-code boundaries. The right rollout starts with those details.

**Interested in connecting AI to your ECC system?** Tell me your ECC release, NetWeaver version and what your team wants to investigate. I can walk you through compatibility, access scope and rollout considerations.

[Contact Manish Kumar Rajak](https://maniabap.dev/#contact)

[Read the project overview](https://maniabap.dev/blog/abap-mcp-server-ecc-702)

## Contributing

Issues and pull requests are welcome, particularly for testing on additional SAP releases and extending read-only capabilities.

Please keep the read-only property intact. Contributions that add a write path will not be merged.

## Licence

MIT. See [LICENSE](LICENSE).

## Acknowledgements

Thanks to the open-source maintainers whose work supports this project. Third-party projects are not affiliated with abap-mcp-702; their licences and credits remain applicable.
