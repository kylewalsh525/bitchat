# Agent Mesh Roadmap (Index)

This roadmap is split into per-phase documents so subagents can own discrete
scopes without stepping on each other.

## Phase Index
- Phase 0: Foundation and Test Harness
  - `docs/AGENT_MESH_ROADMAP/PHASE_0_FOUNDATION.md`
- Phase 1: Real Agent Runtime (Gateway or Local)
  - `docs/AGENT_MESH_ROADMAP/PHASE_1_RUNTIME.md`
- Phase 2: Request Lifecycle Reliability
  - `docs/AGENT_MESH_ROADMAP/PHASE_2_RELIABILITY.md`
- Phase 3: Streaming Responses
  - `docs/AGENT_MESH_ROADMAP/PHASE_3_STREAMING.md`
- Phase 4: Payments (Micropayments)
  - `docs/AGENT_MESH_ROADMAP/PHASE_4_PAYMENTS.md`
- Phase 5: Trust and Quality
  - `docs/AGENT_MESH_ROADMAP/PHASE_5_TRUST.md`
- Phase 6: Sessions and Stateful Agents
  - `docs/AGENT_MESH_ROADMAP/PHASE_6_SESSIONS.md`
- Phase 7: Advanced Routing (Fanout + Bids)
  - `docs/AGENT_MESH_ROADMAP/PHASE_7_ADVANCED_ROUTING.md`

## Current Status (as of now)
- Phase 0: Done
- Phase 1: Partial (runtime + gateway done; dedicated agent setup UI + model catalog pending)
- Phase 2: Done
- Phase 3: Done
- Phase 4: Not started
- Phase 5: Not started
- Phase 6: Partial (session IDs + agent DM threads exist; no session store or /agentsession commands)
- Phase 7: Not started

## Roadmap Focus Update (Distributed LLM Horsepower)
We will fold OpenClaw-style automation needs into existing phases:
- Phase 4: pricing + payment gating for agent work (micropayments)
- Phase 6: enforce ephemeral agent DMs + local memory snippet export
- Phase 7: quality/price/model-hash routing + bid/quote selection

## Working Rules (for Parallel Subagents)
- Each work package owns a small, explicit set of files. Avoid touching files
  owned by other packages.
- If shared files must change (for example, ChatViewModel), add a new extension
  file instead of editing the base type whenever possible.
- Prefer additive changes that preserve protocol backwards compatibility.
- Every package must include tests or a reproducible manual checklist.

## Work Package Template
Each work package in the phase documents lists:
- Goal
- Owned files (exclusive edits)
- Interfaces introduced or modified
- Dependencies (if any)
- Done when (acceptance criteria)

## Cross-Cutting Deliverables (Apply to All Phases)
- Update `docs/AGENT_MESH_IMPLEMENTATION.md` with new code map entries.
- Keep `docs/AGENT_MESH_PROTOCOL.md` in sync with TLV additions and payload types.
- Add manual test scripts to `docs/AGENT_MESH_SETUP.md` per phase.

## Recommended Implementation Order
1) Phase 0 (Foundation)
2) Phase 1 (Real runtime)
3) Phase 2 (Reliability)
4) Phase 3 (Streaming)
5) Phase 6 (Sessions) - unlocks longer workflows
6) Phase 4 (Payments)
7) Phase 5 (Trust)
8) Phase 7 (Advanced routing)

This order keeps the core mesh flow stable before layering payments and trust.
