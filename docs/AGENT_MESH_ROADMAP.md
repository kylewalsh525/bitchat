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
- Phase 4: Payments (Cashu + multi-rail micropayments, mesh-first)
  - `docs/AGENT_MESH_ROADMAP/PHASE_4_PAYMENTS.md`
- Phase 5: Trust and Quality
  - `docs/AGENT_MESH_ROADMAP/PHASE_5_TRUST.md`
- Phase 6: Sessions and Stateful Agents
  - `docs/AGENT_MESH_ROADMAP/PHASE_6_SESSIONS.md`
- Phase 7: Advanced Routing (Tiered Quotes)
  - `docs/AGENT_MESH_ROADMAP/PHASE_7_ADVANCED_ROUTING.md`
- Phase 8: Product Readiness (UX, onboarding, wallet, beta tooling)
  - `docs/AGENT_MESH_ROADMAP/PHASE_8_PRODUCTIZATION.md`

## Current Status (as of now)
- Phase 0: Complete (spec/constants/tests/flags + stable SwiftPM test entrypoint)
- Phase 1: Complete (runtime + gateway + model-discovery UI + requester model/quality/hash preferences)
- Phase 2: Complete (TTL/retry/idempotency + deterministic tests)
- Phase 3: Complete (streaming chunks + assembly + deterministic tests)
- Phase 4: Partial (4A + 4B + 4C + 4D + 4E + 4F-notary + P2PK hardening + 4G x402 baseline implemented; reputation/incentives deferred)
- Phase 5: Deferred (no trust/reputation mechanisms until a privacy-reviewed design is approved)
- Phase 6: Complete (session store/commands, memory UX + auto recall, and payment session state are in-tree)
- Phase 7: Complete (tiered quote routing + tap selection + auto-pick policies + provider tier configuration + quote lifecycle cleanup)
- Phase 8: Complete (beta readiness + polish closeout: onboarding/settings/wallet/allowlist/support export/macOS P2PK + accessibility/copy/validation pass)

## Roadmap Focus Update (Distributed LLM Horsepower)
We will fold OpenClaw-style automation needs into existing phases:
- Phase 4: Cashu pricing + payment gating for agent work; enforce invariant “no final output before payment acceptance”; prefer online mint finality, with explicit risk-managed offline acceptance when configured.
- Phase 6: completed (ephemeral agent DMs + local memory snippet export/recall)
- Phase 7: quality/price/model-hash routing + tiered quote selection (assumes Phase 4 payment terms are available for compatibility filters)

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
- Phase 4A/4B/4C/4D/4E/4F-notary + P2PK hardening + 4G x402 baseline are now in-tree; keep payment packet types (`AgentPaymentPayloadPacket`, `AgentPaymentReceiptPacket`, `MintProxyRequestPacket`, `MintProxyResponsePacket`) plus services (`CashuWalletService`, `CashuMintClient`, `MintGatewayService`, `AgentPaymentBridge`, `AgentPaymentStore`, `AgentPaymentLockKeyStore`, `CashuP2PKService`, `AgentSettlementGossip`, `AgentPaymentNotaryService`, `AgentFairExchangeService`, `X402GatewayClient`, `ThirdwebGuestWalletBridge`) synchronized across protocol + implementation docs, and maintain payment happy-path + settlement-gossip + notary-receipt + relock direct/gateway fallback + mint-unreachable + tranche-streaming + fair-exchange unlock + x402 settle flows in setup docs.

## Phase 4 Payment Interfaces (surfaced here for downstream phases)
- PaymentTerms fields: `paymentRail`, `settlementMode`, `unit`, `priceModel`, `pricePerRequest`, `pricePerInputToken`, `pricePerOutputToken`, `minDeposit`, `granularityTokens`, `acceptedMints`, `requestTTLSeconds`, `requiresLocking`, `x402ChainID`, `x402TokenAddress`, `x402PayTo`, `x402GatewayURL`, `x402FacilitatorID`, `x402Scheme`.
- AgentResponse additions: `paymentRequired`, `paymentRequest`, `paymentError`.
- New packets: `AgentPaymentPayloadPacket`, `AgentPaymentReceiptPacket`; optional `MintProxyRequestPacket` and `MintProxyResponsePacket` for mesh-proxied mint access.
- Payment packets include `sessionID` when available; receipts also bind `paymentID` for multi-tranche ordering safety and optional `fairUnlockKey` for encrypted-release unlock.

## Recommended Implementation Order
1) Phase 0 (Foundation)
2) Phase 1 (Real runtime)
3) Phase 2 (Reliability)
4) Phase 3 (Streaming)
5) Phase 4 (Payments and hardening)
6) Phase 8 (Product readiness: onboarding, settings, wallet UX, macOS locking parity, beta tooling)
7) Phase 7 (Advanced routing: tiered quotes + price/quality/model-hash routing)
8) Phase 5 (Deferred: trust/reputation)

This order keeps the core mesh flow stable, ships payment hardening first, and then adds simplified advanced routing.
Trust/reputation is intentionally deferred.

## Beta Readiness Gate (Phase 8)
Phase 8 is complete when:
- Onboarding is first-run, requester-default, and skippable wallet setup is in-app.
- Settings entrypoint is visible; agent setup/preferences/wallet/panic wipe are discoverable.
- Wallet is usable without commands (import/export/balance) and mint allowlist consent is enforced (fail-closed).
- Wallet UI reflects balance/reserved and x402 connectivity changes live while open (no reopen required).
- P2PK locking uses CashuDevKit on both iOS and macOS (no insecure stubs).
- Support bundle export is redacted (no bearer proofs/tokens/keys) and sufficient for bug reports.
- Panic wipe is visible in Settings and clears local keys, agent/payment/wallet stores, and app support caches.

## Next Best Targets (No Trust/Reputation)
- Phase 4G production hardening:
  - `P4G-OPS-1` Hosted gateway deployment + operational hardening.
  - `P4G-FACIL-1` Thirdweb upstream contract/auth/idempotency hardening.
- Optional rail extensibility:
  - `P4G-EXT-1` Payment rail adapter interface for EVM/Solana follow-ons (keeps offline constraints explicit).
- QA loop:
  - Run `docs/BETA_CHECKLIST.md` as a dogfood matrix and close the top reliability/UX bugs before TestFlight expansion.

## Post-Phase-4 Acceptance Checks (add to release checklist)
- Double-spend attempt to two providers: second provider rejects after settlement gossip propagation. (covered by 4B; keep as regression check)
- Double-spend attempt across disconnected components: exactly one swap settles once mint path exists. (covered by 4C gateway finality path; keep as regression check)
- Replay of `AgentPaymentPayloadPacket` after settlement is rejected. (covered by 4A store/bridge idempotency; keep as regression check)
- Mint unreachable: provider withholds full output; optional preview only. (covered by 4C mesh-proxied finality fallback; keep as regression check)
- Per-token tranche flow: provider pauses/resumes stream around `paymentRequired` interstitials and only marks final chunk after the last tranche is paid. (covered by 4D; keep as regression check)
- Fair exchange unlock flow: requester can decrypt provider-offered ciphertext after receipt unlock key, including receipt-before-offer packet reordering. (covered by 4E; keep as regression check)
- Offline notary threshold: provider rejects offline acceptance when required notary receipt count is not met, and attaches collected receipts when accepted. (covered by 4F-notary; keep as regression check)
- P2PK lock enforced so relays cannot settle intercepted proofs; verify direct relock path and gateway fallback both fail-closed when lock binding is invalid. (covered by current Phase 4 hardening; keep as regression check)
- X402 rail path: requester-side x402 pay flow creates `xpay:` payload and provider-side `/x402/settle` finalizes online with idempotent duplicate receipt behavior. (covered by current Phase 4G baseline; keep as regression check)
- Tiered quote routing: requester can collect provider quotes, choose one tier, and send a quote-bound request (`quoteID` + `quoteOptionID`) with wait-tier semantics enforced. (covered by Phase 7 complete; keep as regression check)
- Quote UX and lifecycle: tap selection, optional auto-pick policy, and unchosen quote TTL cleanup are active and keep draft attachments safe on expiry/dismissal. (covered by Phase 7 complete; keep as regression check)
