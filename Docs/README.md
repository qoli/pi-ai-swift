# Design registry

This directory is the living design and maintenance registry for
`pi-ai-swift`. Architecture defines ownership; the exact target upstream source
defines provider semantics within that boundary. Local code, fixtures, and
executable verification are defeasible evidence, not authority over upstream
behavior. Document completion claims must stay within that evidence.

| Document | Status | Responsibility |
| --- | --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Landed | Public seam, ownership, and semantic-port model |
| [AI_MAINTENANCE.md](AI_MAINTENANCE.md) | Partially landed | Revision sync and accepted-pin defect repair, ownership filtering, semantic evidence, compatibility decisions, and reconstruction |
| [UPSTREAM_GATES.md](UPSTREAM_GATES.md) | Landed | Known upstream capabilities that require a separate cross-repository seam decision |
| [CUSTOM_PROVIDER_RUNTIME_PROPOSAL.md](CUSTOM_PROVIDER_RUNTIME_PROPOSAL.md) | Landed | Public construction seam for static non-bundled API-key providers using existing wire adapters |

## Status meanings

- **Landed:** the declared behavior and cases have executable evidence at the
  recorded revision; this is not a universal semantic-equivalence claim.
- **Partially landed:** a real path exists, but one or more structural gates are
  still missing.
- **Draft:** primarily a proposed design with no meaningful end-to-end path.
- **Retired:** historical context whose current authority moved elsewhere.

Update this registry whenever a document's status changes. Do not promote a
document because its prose is complete; promote it only when the implementation
and verification named by that document exist.
