# Stage 00 — workflow bootstrap

User authorization: create the files required for the supplied operating model.
This stage changes coordination/configuration only; product behavior is unchanged.

| Field | 00-01 |
| --- | --- |
| Description | Establish the agent contract, planning templates and Orca helpers |
| Readiness | Tools pass executable stub tests; actual macOS acceptance result recorded |
| Dependencies | None |
| Files | `AGENTS.md`, `.gitignore`, `plan/**` |
| Level | L3 (shell orchestration and lifecycle coordination) |
| Executor | Initial session, one-time configuration bootstrap |
| Status | done |
| Orca task_id | none — no execution Run created for configuration bootstrap |
| dispatch_id | none |
| Execution failures | 0 |
| Review | Local manual review and CLI compatibility checks; no paid agent launched |
| Acceptance | 20 executable stub tests passed; universal macOS app/widget build, resource checks and codesign verification passed |

This one-time bootstrap is explicitly recorded, rather than represented as an
Orca dispatch that did not occur. All subsequent product work follows AGENTS.md.
