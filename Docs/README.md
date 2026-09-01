# Design registry

This directory is the living design and maintenance registry for
`pi-ai-swift`. Code and executable verification outrank document claims.

| Document | Status | Responsibility |
| --- | --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Landed | Public seam, ownership, and semantic-port model |
| [AI_MAINTENANCE.md](AI_MAINTENANCE.md) | Partially landed | Human-initiated inventory and implementation sync, compatibility decisions, and reconstruction |
| [CUSTOM_PROVIDER_RUNTIME_PROPOSAL.md](CUSTOM_PROVIDER_RUNTIME_PROPOSAL.md) | Landed | Public construction seam for static non-bundled API-key providers using existing wire adapters |

## Status meanings

- **Landed:** the described behavior exists and has executable evidence.
- **Partially landed:** a real path exists, but one or more structural gates are
  still missing.
- **Draft:** primarily a proposed design with no meaningful end-to-end path.
- **Retired:** historical context whose current authority moved elsewhere.

Update this registry whenever a document's status changes. Do not promote a
document because its prose is complete; promote it only when the implementation
and verification named by that document exist.
